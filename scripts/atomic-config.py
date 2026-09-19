#!/usr/bin/env python3
"""Atomically publish one sensitive managed file with durable crash recovery."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


AT_FDCWD = -100
RENAME_NOREPLACE = 1
RENAME_EXCHANGE = 2
MAX_BYTES = 1024 * 1024
EXIT_CONFLICT = 73
EXIT_FAILURE = 74
EXIT_RECOVERY_REQUIRED = 75
JOURNAL_SCHEMA = 1


class UnsafeFile(Exception):
    pass


def digest(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def regular_snapshot(path: Path, *, synchronize: bool = False) -> tuple[os.stat_result, bytes]:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_BYTES:
            raise UnsafeFile()
        chunks: list[bytes] = []
        remaining = info.st_size
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                raise UnsafeFile()
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise UnsafeFile()
        if synchronize:
            os.fsync(descriptor)
        current = os.fstat(descriptor)
        if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns,
                current.st_ctime_ns, current.st_nlink, stat.S_IFMT(current.st_mode)) != (
                info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                info.st_ctime_ns, info.st_nlink, stat.S_IFMT(info.st_mode)):
            raise UnsafeFile()
        return current, b"".join(chunks)
    finally:
        os.close(descriptor)


def optional_snapshot(path: Path) -> tuple[os.stat_result, bytes] | None:
    try:
        os.lstat(path)
    except FileNotFoundError:
        return None
    return regular_snapshot(path)


def same_object(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def matches(info: os.stat_result, contents: bytes, device: int, inode: int,
            expected_digest: str) -> bool:
    return (info.st_dev, info.st_ino) == (device, inode) and digest(contents) == expected_digest


def renameat2(source: Path, target: Path, flags: int) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = getattr(libc, "renameat2", None)
    if function is None:
        raise OSError(errno.ENOSYS, "renameat2 unavailable")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                         ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(AT_FDCWD, os.fsencode(source), AT_FDCWD, os.fsencode(target), flags)
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def fsync_parent(path: Path) -> None:
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def validate_paths(target: Path, candidates: list[Path]) -> os.stat_result:
    expected, candidate = candidates
    if (any(item.parent != target.parent for item in candidates)
            or expected.name == candidate.name
            or not expected.name.startswith(target.name + ".source.")
            or not candidate.name.startswith(target.name + ".tmp.")
            or Path(os.path.realpath(target.parent)) != target.parent):
        raise UnsafeFile()
    parent = os.lstat(target.parent)
    if not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode):
        raise UnsafeFile()
    return parent


def locked(target: Path, expected_parent: os.stat_result):
    lock = target.with_name(target.name + ".crispai-write.lock")
    descriptor = os.open(
        lock,
        os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        0o600,
    )
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise UnsafeFile()
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path_info = os.lstat(lock)
        parent = os.lstat(target.parent)
        if (not same_object(info, path_info)
                or (parent.st_dev, parent.st_ino) !=
                   (expected_parent.st_dev, expected_parent.st_ino)
                or not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode)):
            raise UnsafeFile()
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def journal_path(target: Path) -> Path:
    return target.with_name(target.name + ".crispai-atomic.json")


def journal_next_path(target: Path) -> Path:
    return target.with_name(target.name + ".crispai-atomic.next")


def exact_unlink(path: Path, info: os.stat_result, contents: bytes) -> None:
    current_info, current_contents = regular_snapshot(path)
    if not same_object(current_info, info) or current_contents != contents:
        raise UnsafeFile()
    os.unlink(path)


def record_contents(record: dict) -> bytes:
    return (json.dumps(record, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":")) + "\n").encode("utf-8")


def write_exclusive(path: Path, contents: bytes) -> tuple[os.stat_result, bytes]:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        offset = 0
        while offset < len(contents):
            written = os.write(descriptor, contents[offset:])
            if written <= 0:
                raise OSError(errno.EIO, "journal write failed")
            offset += written
        os.fsync(descriptor)
    except Exception:
        os.close(descriptor)
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    os.close(descriptor)
    info, observed = regular_snapshot(path)
    if stat.S_IMODE(info.st_mode) != 0o600 or observed != contents:
        raise UnsafeFile()
    return info, observed


def validate_digest(value) -> bool:
    return (isinstance(value, str) and len(value) == 64
            and all(character in "0123456789abcdef" for character in value))


def parse_record(target: Path, contents: bytes) -> dict:
    try:
        record = json.loads(contents.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise UnsafeFile() from None
    required = {
        "schema_version", "phase", "action", "target_name", "expected_name", "candidate_name",
        "expected_copy_device", "expected_copy_inode", "expected_copy_sha256",
        "candidate_device", "candidate_inode", "candidate_sha256",
        "target_device", "target_inode", "target_sha256",
    }
    if (not isinstance(record, dict) or set(record) != required
            or type(record["schema_version"]) is not int
            or record["schema_version"] != JOURNAL_SCHEMA
            or record["phase"] not in ("prepared", "committed")
            or record["action"] not in ("replace", "create")
            or record["target_name"] != target.name):
        raise UnsafeFile()
    expected_name = record["expected_name"]
    candidate_name = record["candidate_name"]
    expected_suffix = expected_name.removeprefix(target.name + ".source.") \
        if isinstance(expected_name, str) else ""
    candidate_suffix = candidate_name.removeprefix(target.name + ".tmp.") \
        if isinstance(candidate_name, str) else ""
    if (not isinstance(expected_name, str)
            or not expected_name.startswith(target.name + ".source.")
            or Path(expected_name).name != expected_name
            or not expected_suffix or len(expected_suffix) > 64
            or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
                   for character in expected_suffix)
            or not isinstance(candidate_name, str)
            or not candidate_name.startswith(target.name + ".tmp.")
            or Path(candidate_name).name != candidate_name
            or not candidate_suffix or len(candidate_suffix) > 64
            or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
                   for character in candidate_suffix)):
        raise UnsafeFile()
    for key in ("expected_copy_device", "expected_copy_inode", "candidate_device",
                "candidate_inode", "target_device", "target_inode"):
        if type(record[key]) is not int or record[key] < 0:
            raise UnsafeFile()
    for key in ("expected_copy_sha256", "candidate_sha256", "target_sha256"):
        if not validate_digest(record[key]):
            raise UnsafeFile()
    if record["action"] == "create" and (
            record["target_device"] or record["target_inode"]
            or record["target_sha256"] != digest(b"")):
        raise UnsafeFile()
    return record


def load_journal(target: Path):
    journal = journal_path(target)
    next_journal = journal_next_path(target)
    snapshot = optional_snapshot(journal)
    next_snapshot = optional_snapshot(next_journal)
    if snapshot is None and next_snapshot is None:
        return None
    if snapshot is None:
        next_info, next_contents = next_snapshot
        if stat.S_IMODE(next_info.st_mode) != 0o600:
            raise UnsafeFile()
        next_record = parse_record(target, next_contents)
        if next_record["phase"] != "prepared":
            raise UnsafeFile()
        renameat2(next_journal, journal, RENAME_NOREPLACE)
        fsync_parent(journal)
        snapshot = regular_snapshot(journal)
        if not same_object(snapshot[0], next_info) or snapshot[1] != next_contents:
            raise UnsafeFile()
        next_snapshot = None
    info, contents = snapshot
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise UnsafeFile()
    record = parse_record(target, contents)
    if next_snapshot is not None:
        next_info, next_contents = next_snapshot
        if stat.S_IMODE(next_info.st_mode) != 0o600:
            raise UnsafeFile()
        next_record = parse_record(target, next_contents)
        counterpart = dict(record)
        counterpart["phase"] = "committed" if record["phase"] == "prepared" else "prepared"
        if next_record != counterpart:
            raise UnsafeFile()
        exact_unlink(next_journal, next_info, next_contents)
        fsync_parent(target)
    current_info, current_contents = regular_snapshot(journal)
    if not same_object(current_info, info) or current_contents != contents:
        raise UnsafeFile()
    expected_name = record["expected_name"]
    candidate_name = record["candidate_name"]
    return record, info, contents, target.parent / expected_name, target.parent / candidate_name


def write_journal(target: Path, record: dict) -> tuple[os.stat_result, bytes]:
    journal = journal_path(target)
    next_journal = journal_next_path(target)
    if optional_snapshot(journal) is not None or optional_snapshot(next_journal) is not None:
        raise UnsafeFile()
    contents = record_contents(record)
    next_info, next_contents = write_exclusive(next_journal, contents)
    try:
        renameat2(next_journal, journal, RENAME_NOREPLACE)
        fsync_parent(journal)
    except Exception:
        # A fully written .next file is itself the durable prepared record.  Do not
        # remove it after an uncertain rename; the next invocation will recover it.
        raise
    info, observed = regular_snapshot(journal)
    if not same_object(info, next_info) or observed != next_contents or observed != contents:
        raise UnsafeFile()
    return info, observed


def mark_committed(target: Path, record: dict, journal_info: os.stat_result,
                   journal_contents: bytes):
    if record["phase"] != "prepared":
        raise UnsafeFile()
    committed = dict(record)
    committed["phase"] = "committed"
    contents = record_contents(committed)
    next_journal = journal_next_path(target)
    if optional_snapshot(next_journal) is not None:
        raise UnsafeFile()
    committed_info, committed_contents = write_exclusive(next_journal, contents)
    renameat2(next_journal, journal_path(target), RENAME_EXCHANGE)
    fsync_parent(target)
    info, observed = regular_snapshot(journal_path(target))
    old_info, old_contents = regular_snapshot(next_journal)
    if (not same_object(info, committed_info) or observed != committed_contents
            or observed != contents or not same_object(old_info, journal_info)
            or old_contents != journal_contents):
        raise UnsafeFile()
    exact_unlink(next_journal, old_info, old_contents)
    fsync_parent(target)
    return committed, info, observed


def remove_recorded(path: Path, device: int, inode: int, expected_digest: str) -> None:
    snapshot = optional_snapshot(path)
    if snapshot is None:
        return
    info, contents = snapshot
    if not matches(info, contents, device, inode, expected_digest):
        raise UnsafeFile()
    os.unlink(path)


def clear_journal(target: Path, info: os.stat_result, contents: bytes) -> None:
    exact_unlink(journal_path(target), info, contents)
    fsync_parent(target)


def cleanup_recovery(target: Path, record: dict, journal_info: os.stat_result,
                     journal_contents: bytes, expected: Path, candidate: Path) -> None:
    remove_recorded(candidate, record["candidate_device"], record["candidate_inode"],
                    record["candidate_sha256"])
    remove_recorded(expected, record["expected_copy_device"], record["expected_copy_inode"],
                    record["expected_copy_sha256"])
    fsync_parent(target)
    clear_journal(target, journal_info, journal_contents)


def recover_existing(target: Path) -> int:
    loaded = load_journal(target)
    if loaded is None:
        return 0
    record, journal_info, journal_contents, expected, candidate = loaded
    target_snapshot = optional_snapshot(target)
    candidate_snapshot = optional_snapshot(candidate)
    target_is_candidate = bool(
        target_snapshot
        and matches(target_snapshot[0], target_snapshot[1], record["candidate_device"],
                    record["candidate_inode"], record["candidate_sha256"])
    )
    candidate_is_candidate = bool(
        candidate_snapshot
        and matches(candidate_snapshot[0], candidate_snapshot[1], record["candidate_device"],
                    record["candidate_inode"], record["candidate_sha256"])
    )

    if record["phase"] == "committed":
        if not target_is_candidate:
            return EXIT_RECOVERY_REQUIRED
        if record["action"] == "replace":
            if candidate_snapshot is not None:
                candidate_info, candidate_contents = candidate_snapshot
                if not matches(candidate_info, candidate_contents,
                               record["target_device"], record["target_inode"],
                               record["target_sha256"]):
                    return EXIT_RECOVERY_REQUIRED
                exact_unlink(candidate, candidate_info, candidate_contents)
        elif candidate_snapshot is not None:
            return EXIT_RECOVERY_REQUIRED
        remove_recorded(expected, record["expected_copy_device"],
                        record["expected_copy_inode"], record["expected_copy_sha256"])
        final_info, final_contents = regular_snapshot(target)
        if not matches(final_info, final_contents, record["candidate_device"],
                       record["candidate_inode"], record["candidate_sha256"]):
            return EXIT_RECOVERY_REQUIRED
        fsync_parent(target)
        clear_journal(target, journal_info, journal_contents)
        return 0

    if record["action"] == "replace":
        if target_snapshot is None:
            return EXIT_RECOVERY_REQUIRED
        if target_is_candidate:
            if candidate_snapshot is not None:
                displaced_info, displaced_contents = candidate_snapshot
                if not matches(displaced_info, displaced_contents,
                               record["target_device"], record["target_inode"],
                               record["target_sha256"]):
                    # exchange 后 candidate 必须仍是 journal 绑定的原 live 代。
                    # 第三方换代时保留全部现存对象，不能把未知内容恢复为 live。
                    return EXIT_RECOVERY_REQUIRED
                renameat2(target, candidate, RENAME_EXCHANGE)
                restored_info, restored_contents = regular_snapshot(target)
                returned_info, returned_contents = regular_snapshot(candidate)
                if (not same_object(restored_info, displaced_info)
                        or restored_contents != displaced_contents
                        or not matches(returned_info, returned_contents,
                                       record["candidate_device"], record["candidate_inode"],
                                       record["candidate_sha256"])):
                    return EXIT_RECOVERY_REQUIRED
                fsync_parent(target)
            else:
                # The exchange always leaves the displaced live inode at candidate.
                # Its absence therefore proves outside interference, not a safe
                # rollback opportunity; preserve both surviving generations.
                return EXIT_RECOVERY_REQUIRED
        elif candidate_snapshot is not None and not candidate_is_candidate:
            # exchange 后 target 又被第三方换代；两代都必须原样保留供人工核对。
            return EXIT_RECOVERY_REQUIRED
        cleanup_recovery(target, record, journal_info, journal_contents, expected, candidate)
        return 0

    # In a prepared create transaction, any live target that is not the
    # journal-bound candidate is an outside generation.  It is impossible to
    # distinguish a post-publish replacement from a pre-publish concurrent
    # creator, so preserve every recovery object and require explicit review.
    if target_snapshot is not None and not target_is_candidate:
        return EXIT_RECOVERY_REQUIRED
    if target_is_candidate:
        if candidate_snapshot is not None:
            return EXIT_RECOVERY_REQUIRED
        renameat2(target, candidate, RENAME_NOREPLACE)
        if optional_snapshot(target) is not None:
            return EXIT_RECOVERY_REQUIRED
        returned_info, returned_contents = regular_snapshot(candidate)
        if not matches(returned_info, returned_contents, record["candidate_device"],
                       record["candidate_inode"], record["candidate_sha256"]):
            return EXIT_RECOVERY_REQUIRED
        fsync_parent(target)
    elif candidate_snapshot is not None and not candidate_is_candidate:
        return EXIT_RECOVERY_REQUIRED
    cleanup_recovery(target, record, journal_info, journal_contents, expected, candidate)
    return 0


def prepared_record(action: str, target: Path, expected: Path, candidate: Path,
                    target_snapshot: tuple[os.stat_result, bytes] | None,
                    expected_snapshot: tuple[os.stat_result, bytes] | None = None,
                    candidate_snapshot: tuple[os.stat_result, bytes] | None = None) -> dict:
    if expected_snapshot is None:
        expected_snapshot = regular_snapshot(expected, synchronize=True)
    if candidate_snapshot is None:
        candidate_snapshot = regular_snapshot(candidate, synchronize=True)
    expected_info, expected_contents = expected_snapshot
    candidate_info, candidate_contents = candidate_snapshot
    if (stat.S_IMODE(expected_info.st_mode) != 0o600
            or stat.S_IMODE(candidate_info.st_mode) != 0o600):
        raise UnsafeFile()
    if target_snapshot is None:
        target_device = target_inode = 0
        target_digest = digest(b"")
    else:
        target_info, target_contents = target_snapshot
        target_device, target_inode = target_info.st_dev, target_info.st_ino
        target_digest = digest(target_contents)
    return {
        "schema_version": JOURNAL_SCHEMA,
        "phase": "prepared",
        "action": action,
        "target_name": target.name,
        "expected_name": expected.name,
        "candidate_name": candidate.name,
        "expected_copy_device": expected_info.st_dev,
        "expected_copy_inode": expected_info.st_ino,
        "expected_copy_sha256": digest(expected_contents),
        "candidate_device": candidate_info.st_dev,
        "candidate_inode": candidate_info.st_ino,
        "candidate_sha256": digest(candidate_contents),
        "target_device": target_device,
        "target_inode": target_inode,
        "target_sha256": target_digest,
    }


def replace(target: Path, expected: Path, candidate: Path,
            expected_device: int, expected_inode: int) -> int:
    expected_info, expected_contents = regular_snapshot(expected, synchronize=True)
    candidate_info, candidate_contents = regular_snapshot(candidate, synchronize=True)
    if (stat.S_IMODE(expected_info.st_mode) != 0o600
            or stat.S_IMODE(candidate_info.st_mode) != 0o600):
        raise UnsafeFile()
    current_info, current_contents = regular_snapshot(target)
    if ((current_info.st_dev, current_info.st_ino) != (expected_device, expected_inode)
            or current_contents != expected_contents):
        return EXIT_CONFLICT
    record = prepared_record("replace", target, expected, candidate,
                             (current_info, current_contents),
                             (expected_info, expected_contents),
                             (candidate_info, candidate_contents))
    journal_info, journal_contents = write_journal(target, record)
    try:
        renameat2(target, candidate, RENAME_EXCHANGE)
    except OSError as error:
        clear_journal(target, journal_info, journal_contents)
        if error.errno in (errno.ENOENT, errno.EEXIST, errno.ENOTEMPTY):
            return EXIT_CONFLICT
        return EXIT_FAILURE
    try:
        published_info, published_contents = regular_snapshot(target)
        displaced_info, displaced_contents = regular_snapshot(candidate)
        if (not same_object(published_info, candidate_info)
                or published_contents != candidate_contents):
            return EXIT_RECOVERY_REQUIRED
        if ((displaced_info.st_dev, displaced_info.st_ino) !=
                (expected_device, expected_inode)
                or displaced_contents != expected_contents):
            # target 在最终交换瞬间已成为第三代；把该第三代原样换回。
            renameat2(target, candidate, RENAME_EXCHANGE)
            restored_info, restored_contents = regular_snapshot(target)
            returned_info, returned_contents = regular_snapshot(candidate)
            if (not same_object(restored_info, displaced_info)
                    or restored_contents != displaced_contents
                    or not same_object(returned_info, candidate_info)
                    or returned_contents != candidate_contents):
                return EXIT_RECOVERY_REQUIRED
            fsync_parent(target)
            clear_journal(target, journal_info, journal_contents)
            return EXIT_CONFLICT
        fsync_parent(target)
        record, journal_info, journal_contents = mark_committed(
            target, record, journal_info, journal_contents
        )
        displaced_info, displaced_contents = regular_snapshot(candidate)
        if not matches(displaced_info, displaced_contents,
                       record["target_device"], record["target_inode"],
                       record["target_sha256"]):
            return EXIT_RECOVERY_REQUIRED
        exact_unlink(candidate, displaced_info, displaced_contents)
        remove_recorded(expected, record["expected_copy_device"],
                        record["expected_copy_inode"], record["expected_copy_sha256"])
        final_info, final_contents = regular_snapshot(target)
        if not matches(final_info, final_contents, record["candidate_device"],
                       record["candidate_inode"], record["candidate_sha256"]):
            return EXIT_RECOVERY_REQUIRED
        fsync_parent(target)
        clear_journal(target, journal_info, journal_contents)
        return 0
    except (OSError, UnsafeFile):
        return EXIT_RECOVERY_REQUIRED


def create(target: Path, expected: Path, candidate: Path) -> int:
    if optional_snapshot(target) is not None:
        return EXIT_CONFLICT
    record = prepared_record("create", target, expected, candidate, None)
    journal_info, journal_contents = write_journal(target, record)
    try:
        renameat2(candidate, target, RENAME_NOREPLACE)
    except OSError as error:
        clear_journal(target, journal_info, journal_contents)
        if error.errno in (errno.EEXIST, errno.ENOTEMPTY):
            return EXIT_CONFLICT
        return EXIT_FAILURE
    try:
        published_info, published_contents = regular_snapshot(target)
        if not matches(published_info, published_contents, record["candidate_device"],
                       record["candidate_inode"], record["candidate_sha256"]):
            return EXIT_RECOVERY_REQUIRED
        fsync_parent(target)
        record, journal_info, journal_contents = mark_committed(
            target, record, journal_info, journal_contents
        )
        remove_recorded(expected, record["expected_copy_device"],
                        record["expected_copy_inode"], record["expected_copy_sha256"])
        final_info, final_contents = regular_snapshot(target)
        if not matches(final_info, final_contents, record["candidate_device"],
                       record["candidate_inode"], record["candidate_sha256"]):
            return EXIT_RECOVERY_REQUIRED
        fsync_parent(target)
        clear_journal(target, journal_info, journal_contents)
        return 0
    except (OSError, UnsafeFile):
        return EXIT_RECOVERY_REQUIRED


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    subparsers = parser.add_subparsers(dest="action", required=True)
    replace_parser = subparsers.add_parser("replace", add_help=False)
    replace_parser.add_argument("target", type=Path)
    replace_parser.add_argument("expected", type=Path)
    replace_parser.add_argument("candidate", type=Path)
    replace_parser.add_argument("expected_device", type=int)
    replace_parser.add_argument("expected_inode", type=int)
    create_parser = subparsers.add_parser("create", add_help=False)
    create_parser.add_argument("target", type=Path)
    create_parser.add_argument("expected", type=Path)
    create_parser.add_argument("candidate", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    target = Path(os.path.abspath(arguments.target))
    expected = Path(os.path.abspath(arguments.expected))
    candidate = Path(os.path.abspath(arguments.candidate))
    descriptor = None
    try:
        parent = validate_paths(target, [expected, candidate])
        descriptor = locked(target, parent)
        recovery = recover_existing(target)
        if recovery != 0:
            return recovery
        if arguments.action == "replace":
            return replace(target, expected, candidate,
                           arguments.expected_device, arguments.expected_inode)
        return create(target, expected, candidate)
    except (OSError, UnsafeFile, ValueError):
        for recovery_path in (journal_path(target), journal_next_path(target)):
            try:
                os.lstat(recovery_path)
            except FileNotFoundError:
                continue
            except OSError:
                return EXIT_RECOVERY_REQUIRED
            return EXIT_RECOVERY_REQUIRED
        return EXIT_FAILURE
    finally:
        if descriptor is not None:
            os.close(descriptor)


if __name__ == "__main__":
    sys.exit(main())
