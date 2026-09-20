#!/usr/bin/env python3
"""资料应用事务的旧生效代冻结、校验与恢复投影生成。"""

import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
import time
import tarfile
import uuid


MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_SNAPSHOT_BYTES = 50 * 1024 * 1024 * 1024
MUTABLE_MEMBERS = {"cleanup.json", "touched.json", "upload-response.json", "upload-intent.json", "upload-payload"}
METADATA = {
    "data/knowledge-manifest.json": (True, 0o600, MAX_JSON_BYTES),
    "data/knowledge-projection.json": (True, 0o600, MAX_JSON_BYTES),
    "data/runtime/knowledge-profile.json": (False, 0o640, 65536),
    "data/runtime/knowledge-map.json": (True, 0o640, MAX_JSON_BYTES),
    "data/runtime/knowledge-settings.json": (True, 0o640, 65536),
    "data/runtime/knowledge-lexical.json": (True, 0o640, MAX_JSON_BYTES),
}


class RecoveryError(Exception):
    pass


def fail(message):
    raise RecoveryError(message)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def value_hash(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def stable_copy(source, destination, maximum, mode, gid=0):
    """不跟随链接地流式复制，并在复制前后确认来源 inode 没有变化。"""
    source_fd = target_fd = None
    try:
        source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size < 1 \
                or before.st_size > maximum:
            fail("资料恢复来源类型、链接数或大小无效")
        destination.parent.mkdir(parents=True, exist_ok=True)
        target_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        copied = 0
        while True:
            chunk = os.read(source_fd, 1048576)
            if not chunk:
                break
            copied += len(chunk)
            if copied > maximum:
                fail("资料恢复来源在复制期间超出限制")
            view = memoryview(chunk)
            while view:
                written = os.write(target_fd, view)
                if written <= 0:
                    fail("资料恢复目标写入没有推进")
                view = view[written:]
        after = os.fstat(source_fd)
        if copied != before.st_size or file_identity(after) != file_identity(before):
            fail("资料恢复来源在冻结期间发生变化")
        os.fsync(target_fd)
        os.fchmod(target_fd, mode)
        if os.geteuid() == 0:
            os.fchown(target_fd, 0, gid)
        return file_identity(before)
    except OSError:
        fail("资料恢复来源无法安全复制")
    finally:
        if target_fd is not None:
            os.close(target_fd)
        if source_fd is not None:
            os.close(source_fd)


def verify_identity(path, expected):
    try:
        current = path.lstat()
    except OSError:
        fail("资料恢复来源在冻结期间消失")
    if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1 \
            or file_identity(current) != expected:
        fail("资料恢复来源在冻结期间发生变化")


def regular(path, maximum, empty=False):
    try:
        info = path.lstat()
    except OSError:
        fail("资料恢复成员缺失")
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or (not empty and info.st_size < 1) \
            or info.st_size > maximum:
        fail("资料恢复成员类型、链接数或大小无效")
    return info


def expected_owner():
    return 0 if os.geteuid() == 0 else os.geteuid()


def private_file(path, maximum, mode=0o600, empty=False):
    info = regular(path, maximum, empty=empty)
    expected_gid = (1000 if mode == 0o640 else 0) if os.geteuid() == 0 else os.getegid()
    if stat.S_IMODE(info.st_mode) != mode or info.st_uid != expected_owner() or info.st_gid != expected_gid:
        fail("资料恢复成员权限或所有者无效")
    return info


def read_json(path, maximum=MAX_JSON_BYTES):
    regular(path, maximum)
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        fail("资料恢复 JSON 无效")


def atomic_json(path, value, mode, temporary_directory=None, temporary_prefix=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    directory = Path(temporary_directory) if temporary_directory is not None else path.parent
    prefix = temporary_prefix if temporary_prefix is not None else path.name + "."
    descriptor, temporary = tempfile.mkstemp(prefix=prefix, dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), mode)
            if os.geteuid() == 0 and mode == 0o640:
                os.fchown(stream.fileno(), 0, 1000)
            json.dump(value, stream, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def fsync_directory(path):
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        os.fsync(descriptor)
    except OSError:
        fail("资料恢复目录状态无法持久化")
    finally:
        if descriptor is not None:
            os.close(descriptor)


def fsync_tree_directories(root):
    """把新建恢复树的目录项由深到浅持久化。"""
    root_info = root.lstat()
    expected_gid = 0 if os.geteuid() == 0 else os.getegid()
    if not stat.S_ISDIR(root_info.st_mode) or root.is_symlink() \
            or stat.S_IMODE(root_info.st_mode) != 0o700 \
            or root_info.st_uid != expected_owner() or root_info.st_gid != expected_gid:
        fail("资料恢复目录树根不安全")
    directories = [root]
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        parent = Path(directory)
        for name in names:
            member = parent / name
            info = member.lstat()
            if not stat.S_ISDIR(info.st_mode) or member.is_symlink() \
                    or info.st_uid != expected_owner() or info.st_gid != expected_gid \
                    or stat.S_IMODE(info.st_mode) & 0o077:
                fail("资料恢复目录树包含链接或非目录成员")
            directories.append(member)
        for name in files:
            member = parent / name
            info = member.lstat()
            allowed_gid = 1000 if os.geteuid() == 0 and stat.S_IMODE(info.st_mode) == 0o640 else expected_gid
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or member.is_symlink() \
                    or info.st_uid != expected_owner() or info.st_gid != allowed_gid \
                    or stat.S_IMODE(info.st_mode) not in (0o600, 0o640):
                fail("资料恢复目录树包含不安全文件")
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        fsync_directory(directory)


def rename_directory_noreplace(source, destination):
    """Linux 上以 RENAME_NOREPLACE 发布目录；不可用时安全失败。"""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
    except (AttributeError, OSError):
        fail("当前系统不支持安全发布资料恢复目录")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(-100, os.fsencode(source), -100, os.fsencode(destination), 1) != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            fail("已有资料恢复事务，拒绝覆盖")
        fail("资料恢复目录无法安全发布")


def make_private_parents(root, parent):
    """只在本 helper 新建的 stage 内创建 0700 父目录。"""
    try:
        relative = parent.relative_to(root)
    except ValueError:
        fail("资料恢复目标目录越界")
    current = root
    for part in relative.parts:
        current /= part
        current.mkdir(exist_ok=True)
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or current.is_symlink():
            fail("资料恢复目标父目录不安全")
        os.chmod(current, 0o700)


def safe_root(raw):
    root = Path(raw).absolute()
    if str(root) in ("/", "/root", "/opt", "/tmp") or root.resolve() != root or not root.is_dir() or root.is_symlink():
        fail("部署目录无效")
    return root


def recovery_root(root, raw):
    recovery = Path(raw).absolute()
    parent = safe_member(root, "backups/config-history")
    try:
        parent_info = parent.lstat()
    except OSError:
        fail("资料恢复父目录无效")
    if not stat.S_ISDIR(parent_info.st_mode) or parent.is_symlink() \
            or parent_info.st_uid != expected_owner() or stat.S_IMODE(parent_info.st_mode) & 0o022:
        fail("资料恢复父目录无效")
    expected = parent / "materials.recovery"
    if recovery != expected or recovery.is_symlink():
        fail("资料恢复目录不安全")
    return recovery


def safe_member(root, relative):
    parsed = PurePosixPath(relative)
    if parsed.is_absolute() or not parsed.parts or any(part in ("", ".", "..") for part in parsed.parts) \
            or any(ord(character) < 32 for character in relative):
        fail("资料恢复成员路径无效")
    current = root
    for index, part in enumerate(parsed.parts):
        current /= part
        if current.exists() or current.is_symlink():
            try:
                info = current.lstat()
            except OSError:
                fail("资料恢复成员路径状态无效")
            if stat.S_ISLNK(info.st_mode) or index < len(parsed.parts) - 1 and not stat.S_ISDIR(info.st_mode):
                fail("资料恢复成员路径包含链接或非目录父级")
    return current


def controlled_input(root, raw, kind):
    value = Path(raw).absolute()
    try:
        relative = value.relative_to(root).as_posix()
    except ValueError:
        fail("资料恢复参数越出部署目录")
    patterns = {
        "projection": r"tmp/materials-effective\.[A-Za-z0-9]+",
        "snapshot": r"backups/config-history/materials\.applied\.tar\.gz",
        "workspace": r"tmp/materials-workspace\.[A-Za-z0-9]+",
        "current-workspace": r"tmp/materials-workspace-current\.[A-Za-z0-9]+",
        "output": r"tmp/materials-restore\.[A-Za-z0-9]+/materials-restored\.json",
    }
    if kind not in patterns or re.fullmatch(patterns[kind], relative) is None:
        fail("资料恢复参数不在受管临时路径")
    safe = safe_member(root, relative)
    if kind != "output":
        regular(safe, MAX_SNAPSHOT_BYTES if kind == "snapshot" else MAX_JSON_BYTES)
    else:
        if not safe.parent.is_dir() or safe.parent.is_symlink():
            fail("资料恢复输出目录无效")
    return safe


def controlled_upload_source(root, raw):
    value = Path(raw).absolute()
    try:
        relative = value.relative_to(root).as_posix()
    except ValueError:
        fail("知识上传源越出部署目录")
    allowed = relative.startswith("knowledge/") or re.match(
        r"^tmp/materials-restore\.[A-Za-z0-9]+/deploy/knowledge/", relative) is not None
    if not allowed:
        fail("知识上传源不在受管资料目录")
    source = safe_member(root, relative)
    regular(source, 50 * 1024 * 1024)
    return source


def snapshot_projection_list(snapshot):
    try:
        with tarfile.open(snapshot, "r:gz") as archive:
            members = [item for item in archive.getmembers() if item.name == "knowledge/catalog.json"]
            if len(members) != 1 or not members[0].isfile() or members[0].size < 1 \
                    or members[0].size > MAX_JSON_BYTES:
                fail("旧原文包缺少唯一知识目录")
            stream = archive.extractfile(members[0])
            if stream is None:
                fail("旧原文包知识目录不可读")
            catalog = json.loads(stream.read().decode("utf-8"))
    except (tarfile.TarError, OSError, UnicodeDecodeError, json.JSONDecodeError):
        fail("旧原文包知识目录无效")
    libraries = catalog.get("libraries") if isinstance(catalog, dict) else None
    if not isinstance(libraries, list):
        fail("旧原文包知识目录结构无效")
    projections = []
    for library in libraries:
        if not isinstance(library, dict) or type(library.get("enabled")) is not bool \
                or not isinstance(library.get("documents"), list):
            fail("旧原文包知识库结构无效")
        if not library["enabled"]:
            continue
        for document in library["documents"]:
            projection = document.get("projection") if isinstance(document, dict) else None
            if not isinstance(projection, str) or not projection or "/" in projection or "\\" in projection \
                    or any(ord(character) < 32 for character in projection):
                fail("旧原文包知识投影名无效")
            projections.append(projection)
    return sorted(set(projections))


def snapshot_catalog_contract(snapshot):
    """核对规范原文包中的 catalog 与每个登记源文，返回解码目录。"""
    try:
        with tarfile.open(snapshot, "r:gz") as archive:
            members = archive.getmembers()
            by_name = {}
            for member in members:
                if member.name in by_name:
                    fail("旧原文包含重复成员")
                by_name[member.name] = member
            catalog_member = by_name.get("knowledge/catalog.json")
            if catalog_member is None or not catalog_member.isfile() or not 0 < catalog_member.size <= MAX_JSON_BYTES:
                fail("旧原文包缺少唯一知识目录")
            stream = archive.extractfile(catalog_member)
            if stream is None:
                fail("旧原文包知识目录不可读")
            catalog = json.loads(stream.read().decode("utf-8", "strict"))
            libraries = catalog.get("libraries") if isinstance(catalog, dict) else None
            if catalog.get("schema_version") != 2 or not isinstance(catalog.get("revision"), int) \
                    or catalog["revision"] < 0 or not isinstance(libraries, list):
                fail("旧原文包知识目录结构无效")
            library_ids, projections = set(), set()
            for library in libraries:
                if not isinstance(library, dict) or not isinstance(library.get("id"), str) \
                        or not isinstance(library.get("name"), str) or type(library.get("enabled")) is not bool \
                        or not isinstance(library.get("documents"), list) or library["id"] in library_ids:
                    fail("旧原文包知识库结构无效")
                library_ids.add(library["id"])
                document_ids = set()
                for document in library["documents"]:
                    if not isinstance(document, dict) or not isinstance(document.get("id"), str) \
                            or not isinstance(document.get("source"), str) \
                            or not isinstance(document.get("projection"), str) \
                            or not isinstance(document.get("sha256"), str) \
                            or re.fullmatch(r"[a-f0-9]{64}", document["sha256"]) is None \
                            or document["id"] in document_ids or document["projection"] in projections:
                        fail("旧原文包知识文档结构无效")
                    source = PurePosixPath(document["source"])
                    if source.is_absolute() or len(source.parts) != 2 or source.parts[0] != "sources" \
                            or any(part in ("", ".", "..") for part in source.parts):
                        fail("旧原文包知识源路径无效")
                    member = by_name.get(f"knowledge/{library['id']}/{document['source']}")
                    if member is None or not member.isfile() or member.size < 1 or member.size > MAX_SNAPSHOT_BYTES:
                        fail("旧原文包缺少登记的知识源")
                    source_stream = archive.extractfile(member)
                    if source_stream is None:
                        fail("旧原文包知识源不可读")
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: source_stream.read(1048576), b""):
                        digest.update(chunk)
                    if digest.hexdigest() != document["sha256"]:
                        fail("旧原文包知识源与目录摘要不一致")
                    document_ids.add(document["id"])
                    projections.add(document["projection"])
            return catalog
    except (tarfile.TarError, OSError, UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        fail("旧原文包知识代无效")


def generation_contract(recovery, projection, manifest):
    """证明冻结的原文、manifest、map、lexical 和外层投影来自同一已应用代。"""
    catalog = snapshot_catalog_contract(recovery / "source.tar.gz")
    projected = read_json(recovery / "metadata/data/knowledge-projection.json")
    mapping_path = recovery / "metadata/data/runtime/knowledge-map.json"
    lexical_path = recovery / "metadata/data/runtime/knowledge-lexical.json"
    mapping = read_json(mapping_path)
    lexical = read_json(lexical_path)
    enabled = []
    all_documents = 0
    enabled_libraries = []
    for library in catalog["libraries"]:
        all_documents += len(library["documents"])
        if not library["enabled"]:
            continue
        enabled_libraries.append(library["id"])
        for document in library["documents"]:
            enabled.append((library, document))
    expected_names = sorted(document["projection"] for _library, document in enabled)
    files = manifest.get("files")
    if not isinstance(files, dict) or sorted(files) != expected_names or projected != expected_names:
        fail("冻结的 catalog、manifest 与投影清单不同代")
    expected_map = []
    for library, document in enabled:
        record = files.get(document["projection"])
        if not isinstance(record, dict) or record.get("sha256") != document["sha256"]:
            fail("冻结的 catalog 与 manifest 文档不同代")
        for location in record.get("locations", []):
            expected_map.append({"location": safe_location(location), "library_id": library["id"],
                                 "library_name": library["name"], "document_id": document["id"],
                                 "projection": document["projection"]})
    if mapping != {"schema_version": 2, "revision": catalog["revision"], "documents": expected_map}:
        fail("冻结的知识 map 与 catalog/manifest 不同代")
    knowledge = projection.get("knowledge") if isinstance(projection, dict) else None
    if not isinstance(knowledge, dict) or knowledge.get("catalog_revision") != catalog["revision"] \
            or knowledge.get("library_count") != len(catalog["libraries"]) \
            or knowledge.get("document_count") != all_documents \
            or knowledge.get("enabled_document_count") != len(expected_map) \
            or knowledge.get("enabled_library_ids") != enabled_libraries:
        fail("冻结的知识统计与原文不同代")
    if not isinstance(lexical, dict) or lexical.get("schema_version") != 2 \
            or lexical.get("map_sha256") != file_hash(mapping_path):
        fail("冻结的词法索引与 map 不同代")
    payload = {key: value for key, value in lexical.items() if key != "payload_sha256"}
    if lexical.get("payload_sha256") != value_hash(payload) or not isinstance(lexical.get("passages"), list):
        fail("冻结的词法索引完整性无效")
    mapped = {item["location"]: item for item in expected_map}
    for passage in lexical["passages"]:
        source = mapped.get(passage.get("location")) if isinstance(passage, dict) else None
        if source is None or any(passage.get(key) != source[key]
                                 for key in ("library_id", "document_id", "projection", "location")):
            fail("冻结的词法片段引用了非当前 map 文档")


def member_hash(root, relative, maximum=MAX_JSON_BYTES):
    target = safe_member(root, relative)
    regular(target, maximum)
    return file_hash(target)


def safe_location(value):
    if not isinstance(value, str) or len(value.encode("utf-8")) > 1024 or "\\" in value \
            or any(ord(character) < 32 or ord(character) == 127 for character in value):
        fail("知识位置无效")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or len(parsed.parts) != 2 or parsed.parts[0] != "custom-documents" \
            or any(part in ("", ".", "..") for part in parsed.parts) or not value.endswith(".json"):
        fail("知识位置无效")
    return value


def cache_path(root, location):
    name = str(uuid.uuid5(uuid.NAMESPACE_URL, safe_location(location))) + ".json"
    return safe_member(root, "data/anythingllm/vector-cache/" + name)


def locations(value):
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        fail("工作区位置清单无效")
    checked = [safe_location(item) for item in value]
    if len(checked) != len(set(checked)) or len(checked) > 100000:
        fail("工作区位置清单重复或过大")
    return sorted(checked)


def canonical_locations(value):
    checked = locations(value)
    if value != checked:
        fail("工作区位置清单不是规范排序")
    return checked


def location_contract(complete):
    """把 v1/v2 恢复清单解释成唯一的位置权限视图。"""
    managed = locations(complete.get("managed_locations"))
    if complete.get("schema_version") == 1:
        observed = locations(complete.get("workspace_locations"))
        if not set(managed).issubset(observed):
            fail("冻结时工作区缺少旧代受管位置")
        return {"mode": "verified", "managed": managed, "observed": observed,
                "protected": observed, "deletable": managed, "missing": []}
    if complete.get("schema_version") != 2:
        fail("资料恢复清单版本无效")
    managed = canonical_locations(complete.get("managed_locations"))
    observed = canonical_locations(complete.get("observed_workspace_locations"))
    protected = canonical_locations(complete.get("protected_workspace_locations"))
    deletable = canonical_locations(complete.get("deletable_managed_locations"))
    missing = canonical_locations(complete.get("missing_managed_locations"))
    expected_protected = sorted(set(observed) | set(managed))
    expected_deletable = sorted(set(observed) & set(managed))
    expected_missing = sorted(set(managed) - set(observed))
    if protected != expected_protected or deletable != expected_deletable or missing != expected_missing:
        fail("资料恢复位置权限集合不一致")
    mode = complete.get("capture_mode")
    if mode not in ("verified", "external_repair") or mode == "verified" and missing:
        fail("资料恢复捕获模式与外部状态不一致")
    return {"mode": mode, "managed": managed, "observed": observed,
            "protected": protected, "deletable": deletable, "missing": missing}


def profile_contract(profile, manifest):
    files = manifest.get("files")
    if manifest.get("version") != 1 or not isinstance(files, dict) \
            or manifest.get("pending_files") != {} or manifest.get("garbage_locations") != []:
        fail("旧知识 manifest 不是完整已应用状态")
    if profile is None:
        if files or manifest.get("embedding_profile") not in (None, ""):
            fail("非空知识代缺少 profile")
        return []
    if not isinstance(profile, dict) or profile.get("schema_version") != 1 or profile.get("state") != "applied" \
            or not isinstance(profile.get("profile"), dict) or profile.get("fingerprint") != value_hash(profile["profile"]):
        fail("旧知识 profile 无效")
    key = profile["fingerprint"]
    if manifest.get("embedding_profile") != key:
        fail("旧知识 profile 与 manifest 不同代")
    managed = []
    seen = set()
    for name, record in files.items():
        if not isinstance(name, str) or not name or not isinstance(record, dict) \
                or record.get("embedding_profile") != key:
            fail("旧知识文档记录无效")
        item_locations = record.get("locations")
        bindings = record.get("cache_bindings")
        if not isinstance(item_locations, list) or not item_locations or not isinstance(bindings, list) \
                or len(item_locations) != len(bindings):
            fail("旧知识位置或缓存绑定不完整")
        expected = {}
        for item in bindings:
            if not isinstance(item, dict) or set(item) != {"location", "sha256"} \
                    or not isinstance(item.get("sha256"), str) or len(item["sha256"]) != 64 \
                    or any(character not in "0123456789abcdef" for character in item["sha256"]):
                fail("旧知识缓存绑定无效")
            location = safe_location(item.get("location"))
            if location in expected:
                fail("旧知识缓存绑定重复")
            expected[location] = item["sha256"]
        checked = [safe_location(item) for item in item_locations]
        if set(checked) != set(expected) or any(item in seen for item in checked):
            fail("旧知识位置与缓存绑定不一致")
        managed.extend(checked)
        seen.update(checked)
    return sorted(managed)


def validate_live_bindings(root, profile, manifest):
    if profile is None:
        return
    for record in manifest["files"].values():
        bindings = {item["location"]: item["sha256"] for item in record["cache_bindings"]}
        for location in record["locations"]:
            cached = cache_path(root, location)
            regular(cached, MAX_SNAPSHOT_BYTES)
            if file_hash(cached) != bindings[location]:
                fail("旧知识缓存与冻结绑定不一致")


def inventory(directory):
    result = []
    for child in sorted(directory.rglob("*"), key=lambda item: os.fsencode(item.relative_to(directory).as_posix())):
        info = child.lstat()
        relative = child.relative_to(directory).as_posix()
        if stat.S_ISDIR(info.st_mode):
            result.append({"path": relative, "type": "directory", "mode": stat.S_IMODE(info.st_mode),
                           "uid": info.st_uid, "gid": info.st_gid})
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            result.append({"path": relative, "type": "file", "mode": stat.S_IMODE(info.st_mode),
                           "uid": info.st_uid, "gid": info.st_gid,
                           "size": info.st_size, "sha256": file_hash(child)})
        else:
            fail("资料恢复包含链接、硬链接或特殊文件")
    return result


def validate_complete(root, recovery):
    try:
        recovery_info = recovery.lstat()
    except OSError:
        fail("资料恢复目录缺失")
    if not stat.S_ISDIR(recovery_info.st_mode) or stat.S_IMODE(recovery_info.st_mode) != 0o700 \
            or recovery_info.st_uid != expected_owner() \
            or recovery_info.st_gid != (0 if os.geteuid() == 0 else os.getegid()):
        fail("资料恢复目录权限或所有者无效")
    private_file(recovery / "complete.json", 1048576)
    complete = read_json(recovery / "complete.json", 1048576)
    required_v1 = {"schema_version", "created_at", "projection_sha256", "source_sha256", "metadata_presence",
                   "managed_locations", "workspace_locations", "inventory"}
    required_v2 = {"schema_version", "capture_mode", "created_at", "projection_sha256", "source_sha256",
                   "metadata_presence", "managed_locations", "observed_workspace_locations",
                   "protected_workspace_locations", "deletable_managed_locations",
                   "missing_managed_locations", "inventory"}
    if not isinstance(complete, dict) or complete.get("schema_version") not in (1, 2) \
            or (complete.get("schema_version") == 1 and set(complete) != required_v1) \
            or (complete.get("schema_version") == 2 and set(complete) != required_v2) \
            or type(complete.get("created_at")) is not int or complete["created_at"] < 0:
        fail("资料恢复清单无效")
    expected_inventory = complete["inventory"]
    actual_inventory = [item for item in inventory(recovery)
                        if item["path"] not in MUTABLE_MEMBERS and item["path"] != "complete.json"]
    if expected_inventory != actual_inventory:
        fail("资料恢复包成员已改变")
    private_file(recovery / "projection.json", MAX_JSON_BYTES)
    private_file(recovery / "source.tar.gz", MAX_SNAPSHOT_BYTES)
    projection = read_json(recovery / "projection.json")
    if file_hash(recovery / "projection.json") != complete["projection_sha256"] \
            or file_hash(recovery / "source.tar.gz") != complete["source_sha256"]:
        fail("资料恢复投影或原文包已改变")
    presence = complete["metadata_presence"]
    if not isinstance(presence, dict) or set(presence) != set(METADATA) \
            or any(type(value) is not bool for value in presence.values()):
        fail("资料恢复元数据存在性清单无效")
    for relative, (required_member, expected_mode, maximum) in METADATA.items():
        member = recovery / "metadata" / relative
        if presence[relative]:
            private_file(member, maximum, expected_mode)
        elif required_member or member.exists() or member.is_symlink():
            fail("资料恢复元数据缺失或出现额外成员")
    manifest = read_json(recovery / "metadata/data/knowledge-manifest.json")
    profile = read_json(recovery / "metadata/data/runtime/knowledge-profile.json", 65536) \
        if presence["data/runtime/knowledge-profile.json"] else None
    managed = profile_contract(profile, manifest)
    contract = location_contract(complete)
    if managed != contract["managed"]:
        fail("资料恢复受管位置清单不一致")
    knowledge = projection.get("knowledge") if isinstance(projection, dict) else None
    if projection.get("schema_version") != 2 or projection.get("state") != "applied" or not isinstance(knowledge, dict):
        fail("冻结的旧资料投影无效")
    expected = {
        "data/knowledge-manifest.json": knowledge.get("manifest_sha256"),
        "data/runtime/knowledge-map.json": knowledge.get("map_sha256"),
        "data/runtime/knowledge-settings.json": knowledge.get("settings_sha256"),
        "data/runtime/knowledge-profile.json": knowledge.get("profile_sha256"),
        "data/runtime/knowledge-lexical.json": knowledge.get("lexical_sha256"),
    }
    for relative, digest in expected.items():
        member = recovery / "metadata" / relative
        actual = file_hash(member) if presence[relative] else ""
        if not isinstance(digest, str) or actual != digest:
            fail("旧资料投影与恢复元数据摘要不一致")
    generation_contract(recovery, projection, manifest)
    touched_path = recovery / "touched.json"
    touched_locations = []
    if touched_path.exists() or touched_path.is_symlink():
        private_file(touched_path, MAX_JSON_BYTES)
        touched = read_json(touched_path)
        if not isinstance(touched, dict) or set(touched) != {"schema_version", "locations"} \
                or touched.get("schema_version") != 1:
            fail("资料恢复上传位置账本无效")
        touched_locations = locations(touched.get("locations"))
        if complete["schema_version"] == 2 and touched.get("locations") != touched_locations:
            fail("资料恢复上传位置账本不是规范排序")
        forbidden_touched = set(touched_locations) & set(contract["protected"]) - set(contract["deletable"])
        if forbidden_touched:
            fail("资料恢复上传位置账本包含无连续所有权的位置")
    cleanup_path = recovery / "cleanup.json"
    if cleanup_path.exists() or cleanup_path.is_symlink():
        private_file(cleanup_path, MAX_JSON_BYTES)
        cleanup = read_json(cleanup_path)
        if not isinstance(cleanup, dict) or set(cleanup) != {"schema_version", "locations"} \
                or cleanup.get("schema_version") != 1:
            fail("资料恢复清理责任无效")
        cleanup_locations = locations(cleanup.get("locations"))
        if complete["schema_version"] == 2 and cleanup.get("locations") != cleanup_locations:
            fail("资料恢复清理责任不是规范排序")
        allowed_cleanup = set(contract["deletable"]) | set(touched_locations)
        if set(cleanup_locations) - allowed_cleanup or set(cleanup_locations) & set(contract["missing"]):
            fail("资料恢复清理责任包含未授权位置")
    response_path = recovery / "upload-response.json"
    if response_path.exists() or response_path.is_symlink():
        private_file(response_path, MAX_JSON_BYTES, empty=True)
    intent_path = recovery / "upload-intent.json"
    if intent_path.exists() or intent_path.is_symlink():
        private_file(intent_path, 65536)
        intent = read_json(intent_path, 65536)
        filename = intent.get("filename") if isinstance(intent, dict) else None
        if set(intent) != {"schema_version", "attempt_id", "filename", "upload_filename", "created_at",
                           "baseline_matches", "payload_sha256", "payload_size"} \
                or intent.get("schema_version") != 2 \
                or not isinstance(intent.get("attempt_id"), str) \
                or re.fullmatch(r"[a-f0-9]{32}", intent["attempt_id"]) is None \
                or not isinstance(filename, str) or filename in ("", ".", "..") or len(filename.encode("utf-8")) > 255 \
                or "/" in filename or "\\" in filename or ";" in filename or "," in filename \
                or any(ord(character) < 32 or ord(character) == 127 for character in filename) \
                or re.search(r"\.([A-Za-z0-9]{1,16})$", filename) is None \
                or intent.get("upload_filename") != "crispai-upload-" + intent["attempt_id"] + "." \
                    + filename.rsplit(".", 1)[-1].lower() \
                or not isinstance(intent.get("payload_sha256"), str) \
                or re.fullmatch(r"[a-f0-9]{64}", intent["payload_sha256"]) is None \
                or type(intent.get("payload_size")) is not int or not 0 < intent["payload_size"] <= 50 * 1024 * 1024 \
                or not isinstance(intent.get("created_at"), int) or intent["created_at"] < 0:
            fail("知识上传意图记录无效")
        locations(intent.get("baseline_matches"))
        payload_path = recovery / "upload-payload"
        private_file(payload_path, 50 * 1024 * 1024)
        if payload_path.stat().st_size != intent["payload_size"] \
                or file_hash(payload_path) != intent["payload_sha256"]:
            fail("知识上传恢复正文与意图记录不一致")
    elif (recovery / "upload-payload").exists() or (recovery / "upload-payload").is_symlink():
        fail("存在无意图记录的知识上传正文")
    return complete, projection


def upload_matches(root, filename):
    document_root = safe_member(root, "data/anythingllm/documents/custom-documents")
    if not document_root.is_dir() or document_root.is_symlink():
        fail("知识源文档目录无效")
    matches = []
    prefixes = (filename + ".", filename + "-")
    for member in document_root.iterdir():
        try:
            info = member.lstat()
        except OSError:
            fail("知识源文档状态无效")
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or member.is_symlink():
            fail("知识源文档目录含链接或特殊文件")
        name = member.name
        if name == filename + ".json" or name.endswith(".json") and name.startswith(prefixes):
            matches.append(safe_location("custom-documents/" + name))
    return sorted(set(matches))


def validate_orphan_tree(path):
    """只允许删除本 helper 自己留下、由当前身份拥有的普通目录树。"""
    try:
        root_info = path.lstat()
    except OSError:
        fail("资料恢复临时目录状态无效")
    expected_gid = 0 if os.geteuid() == 0 else os.getegid()
    if not stat.S_ISDIR(root_info.st_mode) or path.is_symlink() \
            or stat.S_IMODE(root_info.st_mode) != 0o700 \
            or root_info.st_uid != expected_owner() or root_info.st_gid != expected_gid:
        fail("资料恢复临时目录归属或权限无效")
    total = 0
    for directory, names, files in os.walk(path, topdown=True, followlinks=False):
        for name in names + files:
            member = Path(directory) / name
            try:
                info = member.lstat()
            except OSError:
                fail("资料恢复临时成员状态无效")
            if stat.S_ISDIR(info.st_mode):
                if member.is_symlink() or info.st_uid != expected_owner() or info.st_gid != expected_gid \
                        or stat.S_IMODE(info.st_mode) & 0o022:
                    fail("资料恢复临时目录包含不安全成员")
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 \
                    or info.st_uid != expected_owner() \
                    or info.st_gid != (1000 if os.geteuid() == 0 and stat.S_IMODE(info.st_mode) == 0o640
                                       else expected_gid) \
                    or stat.S_IMODE(info.st_mode) & 0o022:
                fail("资料恢复临时目录包含链接或特殊成员")
            total += info.st_size
            if total > MAX_SNAPSHOT_BYTES + 4 * MAX_JSON_BYTES:
                fail("资料恢复临时目录异常过大")


def cleanup_sibling_orphans(recovery):
    """清理由 SIGKILL 留下的、名称和归属均严格匹配的同级临时对象。"""
    stage_pattern = re.compile(r"materials\.recovery\.[A-Za-z0-9_]{8}")
    file_pattern = re.compile(
        r"(?:(materials\.recovery\.(upload-payload|upload-intent|touched|cleanup)\."
        r"(?:[A-Za-z0-9_]{8}|[a-f0-9]{32}))|"
        r"(materials\.applied\.tar\.gz\.tmp\.[A-Za-z0-9_]{8}))")
    removed = []
    for member in recovery.parent.iterdir():
        match = file_pattern.fullmatch(member.name)
        if stage_pattern.fullmatch(member.name):
            validate_orphan_tree(member)
            try:
                shutil.rmtree(member)
            except OSError:
                fail("资料恢复临时目录无法清理")
            removed.append(member.name)
            continue
        if match is None:
            continue
        kind = match.group(2)
        maximum = MAX_SNAPSHOT_BYTES if match.group(3) is not None \
            else 50 * 1024 * 1024 if kind == "upload-payload" else MAX_JSON_BYTES
        private_file(member, maximum, empty=True)
        try:
            member.unlink()
        except OSError:
            fail("资料恢复临时文件无法清理")
        removed.append(member.name)
    if removed:
        fsync_directory(recovery.parent)
    return sorted(removed)


def cleanup_upload_orphan(recovery):
    payload = recovery / "upload-payload"
    intent = recovery / "upload-intent.json"
    response = recovery / "upload-response.json"
    if not payload.exists() and not payload.is_symlink():
        return False
    if intent.exists() or intent.is_symlink() or response.exists() or response.is_symlink():
        return False
    # 正文固定路径只会在网络请求前建立。若意图和响应均不存在，零字节或
    # 复制到一半的文件也没有外部副作用，可按严格归属安全删除。
    private_file(payload, 50 * 1024 * 1024, empty=True)
    payload.unlink()
    fsync_directory(recovery)
    return True


def begin_upload(root, recovery, filename, source_raw):
    cleanup_sibling_orphans(recovery)
    cleanup_upload_orphan(recovery)
    validate_complete(root, recovery)
    source = controlled_upload_source(root, source_raw)
    if not isinstance(filename, str) or filename in ("", ".", "..") or len(filename.encode("utf-8")) > 255 \
            or "/" in filename or "\\" in filename or ";" in filename or "," in filename \
            or any(ord(character) < 32 or ord(character) == 127 for character in filename):
        fail("知识上传文件名无效")
    intent_path = recovery / "upload-intent.json"
    response_path = recovery / "upload-response.json"
    payload_path = recovery / "upload-payload"
    if intent_path.exists() or intent_path.is_symlink() or response_path.exists() or response_path.is_symlink() \
            or payload_path.exists() or payload_path.is_symlink():
        fail("已有未收口的知识上传责任")
    match = re.search(r"\.([A-Za-z0-9]{1,16})$", filename)
    if match is None:
        fail("知识上传文件扩展名无效")
    attempt = uuid.uuid4().hex
    upload_filename = "crispai-upload-" + attempt + "." + match.group(1).lower()
    payload_temporary = recovery.with_name(recovery.name + ".upload-payload." + uuid.uuid4().hex)
    try:
        identity = stable_copy(source, payload_temporary, 50 * 1024 * 1024, 0o600)
        verify_identity(source, identity)
        os.replace(payload_temporary, payload_path)
        fsync_directory(recovery)
        intent = {"schema_version": 2, "attempt_id": attempt, "filename": filename,
                  "upload_filename": upload_filename, "created_at": int(time.time()),
                  "baseline_matches": upload_matches(root, upload_filename),
                  "payload_sha256": file_hash(payload_path), "payload_size": payload_path.stat().st_size}
        atomic_json(intent_path, intent, 0o600, recovery.parent,
                    recovery.name + ".upload-intent.")
        fsync_directory(recovery)
    except (RecoveryError, OSError):
        payload_temporary.unlink(missing_ok=True)
        payload_path.unlink(missing_ok=True)
        raise
    return intent


def resolve_upload(root, recovery):
    validate_complete(root, recovery)
    intent_path = recovery / "upload-intent.json"
    if not intent_path.exists() and not intent_path.is_symlink():
        fail("知识上传意图记录缺失")
    intent = read_json(intent_path, 65536)
    filename = intent["upload_filename"]
    baseline = set(locations(intent["baseline_matches"]))
    matches = sorted(set(upload_matches(root, filename)) - baseline)
    # alias 含本事务的随机 attempt，所有 post-baseline 同 alias 结果都
    # 来自本责任的崩溃重放；一律登记后精确清理。空集由 Shell
    # 使用冻结 payload 重放，不在这里假定请求从未发出。
    return matches


def mutable_location_list(recovery, name):
    path = recovery / name
    if not path.exists() and not path.is_symlink():
        return []
    private_file(path, MAX_JSON_BYTES)
    value = read_json(path)
    if not isinstance(value, dict) or set(value) != {"schema_version", "locations"} \
            or value.get("schema_version") != 1:
        fail("资料恢复位置账本无效")
    return locations(value.get("locations"))


def stdin_locations():
    raw = sys.stdin.buffer.read(MAX_JSON_BYTES + 1)
    if not raw or len(raw) > MAX_JSON_BYTES:
        fail("资料恢复位置输入大小无效")
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        fail("资料恢复位置输入 JSON 无效")
    return locations(value)


def record_touched(root, recovery, additions):
    """在收口上传意图前持久登记本事务取得连续所有权的位置。"""
    complete, _projection = validate_complete(root, recovery)
    contract = location_contract(complete)
    additions = locations(additions)
    if not additions:
        fail("资料恢复上传位置为空")
    aliases = set(resolve_upload(root, recovery))
    allowed = aliases | (set(additions) & set(contract["deletable"]))
    if set(additions) != allowed:
        fail("知识上传位置没有连续所有权证据")
    merged = sorted(set(mutable_location_list(recovery, "touched.json")) | set(additions))
    atomic_json(recovery / "touched.json", {"schema_version": 1, "locations": merged}, 0o600,
                recovery.parent, recovery.name + ".touched.")
    fsync_directory(recovery)
    validate_complete(root, recovery)


def write_cleanup(root, recovery, requested):
    """在执行两段外部删除前持久登记完整清理责任。"""
    requested = locations(requested)
    if not requested:
        fail("资料恢复清理位置为空")
    cleanup_path = recovery / "cleanup.json"
    if cleanup_path.exists() or cleanup_path.is_symlink():
        fail("已有未收口的资料恢复清理责任")
    classified = classify_delete(root, recovery, requested)
    if classified["preserve_missing"] or classified["delete"] != requested:
        fail("资料恢复清理位置没有完整删除授权")
    atomic_json(cleanup_path, {"schema_version": 1, "locations": requested}, 0o600,
                recovery.parent, recovery.name + ".cleanup.")
    fsync_directory(recovery)
    validate_complete(root, recovery)


def settle_cleanup(root, recovery, removed):
    """外部删除完成后，先持久移除责任，再收窄可重建的 touched 集。"""
    validate_complete(root, recovery)
    removed = locations(removed)
    cleanup_path = recovery / "cleanup.json"
    if not cleanup_path.exists() and not cleanup_path.is_symlink():
        fail("资料恢复清理责任缺失")
    cleanup = read_json(cleanup_path)
    if not isinstance(cleanup, dict) or set(cleanup) != {"schema_version", "locations"} \
            or cleanup.get("schema_version") != 1 or locations(cleanup.get("locations")) != removed:
        fail("资料恢复清理责任与完成范围不一致")
    cleanup_path.unlink()
    # 先持久收口 cleanup。若随后崩溃，剩余 touched 会在重入时幂等重建责任；
    # 反向顺序会留下引用已移除位置但失去 touched 授权的无效 cleanup。
    fsync_directory(recovery)
    touched_path = recovery / "touched.json"
    if touched_path.exists() or touched_path.is_symlink():
        remaining = sorted(set(mutable_location_list(recovery, "touched.json")) - set(removed))
        if remaining:
            atomic_json(touched_path, {"schema_version": 1, "locations": remaining}, 0o600,
                        recovery.parent, recovery.name + ".touched.")
        else:
            touched_path.unlink()
        fsync_directory(recovery)
    validate_complete(root, recovery)


def finish_upload(root, recovery):
    """touched 已持久后，成套移除上传意图、正文和回执并持久化目录项。"""
    validate_complete(root, recovery)
    for name in ("upload-response.json", "upload-intent.json", "upload-payload"):
        path = recovery / name
        if path.exists() or path.is_symlink():
            path.unlink()
            # 顺序持久：先去回执（重入仍可由 intent/alias 恢复），再去意图
            # （仅余 payload 时 cleanup-upload-orphan 可安全收口），最后去正文。
            # 不把三个 unlink 留在一个未持久的掉电窗口内。
            fsync_directory(recovery)
    validate_complete(root, recovery)


def finish_tracking(root, recovery):
    """外部回读成功后持久收口最后的 touched 责任。"""
    validate_complete(root, recovery)
    for name in ("cleanup.json", "upload-response.json", "upload-intent.json", "upload-payload"):
        if (recovery / name).exists() or (recovery / name).is_symlink():
            fail("资料恢复仍有未收口的外部责任")
    touched = recovery / "touched.json"
    if touched.exists() or touched.is_symlink():
        touched.unlink()
        fsync_directory(recovery)
    validate_complete(root, recovery)


def classify_delete(root, recovery, requested):
    """把删除请求分为连续所有权位置与只解除本地引用的 missing。"""
    complete, _projection = validate_complete(root, recovery)
    contract = location_contract(complete)
    requested_locations = locations(requested)
    touched = mutable_location_list(recovery, "touched.json")
    allowed = set(contract["deletable"]) | set(touched)
    missing = set(contract["missing"])
    rejected = set(requested_locations) - allowed - missing
    if rejected:
        fail("知识删除请求包含未授权位置")
    return {"schema_version": 1,
            "delete": sorted(set(requested_locations) & allowed),
            "preserve_missing": sorted(set(requested_locations) & missing)}


def repair_scope(root, recovery):
    """只从冻结 canonical 与 recovery 权限集合派生外部修复范围。"""
    complete, _projection = validate_complete(root, recovery)
    contract = location_contract(complete)
    missing = set(contract["missing"])
    if not missing:
        return {"schema_version": 1, "projections": []}
    manifest = read_json(recovery / "metadata/data/knowledge-manifest.json")
    catalog = snapshot_catalog_contract(recovery / "source.tar.gz")
    enabled = {document["projection"] for library in catalog["libraries"] if library["enabled"]
               for document in library["documents"]}
    result = []
    covered = set()
    for projection_name in sorted(manifest.get("files", {})):
        record = manifest["files"][projection_name]
        old_locations = locations(record.get("locations"))
        missing_locations = sorted(set(old_locations) & missing)
        if not missing_locations:
            continue
        if projection_name not in enabled:
            fail("缺失知识位置没有对应的冻结启用文档")
        if covered & set(missing_locations):
            fail("缺失知识位置映射到多个冻结文档")
        covered.update(missing_locations)
        result.append({"projection": projection_name,
                       "missing_locations": missing_locations,
                       "deletable_old_locations": sorted(
                           set(old_locations) & set(contract["deletable"]))})
    if covered != missing:
        fail("缺失知识位置无法唯一映射到冻结文档")
    return {"schema_version": 1, "projections": result}


def retired_directories(recovery):
    prefix = recovery.name + ".retired."
    result = []
    for member in recovery.parent.iterdir():
        if not member.name.startswith(prefix):
            continue
        suffix = member.name[len(prefix):]
        if re.fullmatch(r"[a-f0-9]{32}", suffix) is None:
            continue
        try:
            info = member.lstat()
        except OSError:
            continue
        expected_gid = 0 if os.geteuid() == 0 else os.getegid()
        if not stat.S_ISDIR(info.st_mode) or member.is_symlink() \
                or info.st_uid != expected_owner() or info.st_gid != expected_gid \
                or stat.S_IMODE(info.st_mode) != 0o700:
            fail("已退役资料事务目录不安全")
        result.append(member)
    return result


def cleanup_retired(recovery):
    pending = []
    removed = False
    for member in retired_directories(recovery):
        try:
            shutil.rmtree(member)
            removed = True
        except OSError:
            pending.append(member.name)
    if removed:
        fsync_directory(recovery.parent)
    return not pending


def retire(root, recovery):
    validate_complete(root, recovery)
    if any((recovery / name).exists() or (recovery / name).is_symlink() for name in MUTABLE_MEMBERS):
        fail("资料恢复仍有未完成的外部责任，拒绝退役事务")
    tombstone = recovery.with_name(recovery.name + ".retired." + uuid.uuid4().hex)
    rename_directory_noreplace(recovery, tombstone)
    fsync_directory(recovery.parent)
    return cleanup_retired(recovery)


def capture(root, recovery, projection_path, snapshot_path, workspace_path, capture_mode):
    if capture_mode not in ("verified", "external_repair"):
        fail("资料恢复捕获模式无效")
    cleanup_sibling_orphans(recovery)
    projection_path = controlled_input(root, projection_path, "projection")
    snapshot_path = controlled_input(root, snapshot_path, "snapshot")
    workspace_path = controlled_input(root, workspace_path, "workspace")
    regular(snapshot_path, MAX_SNAPSHOT_BYTES)
    required_bytes = snapshot_path.stat().st_size + projection_path.stat().st_size
    for relative, (_required, _mode, maximum) in METADATA.items():
        source = safe_member(root, relative)
        if source.exists() or source.is_symlink():
            required_bytes += regular(source, maximum).st_size
    if shutil.disk_usage(recovery.parent).free < required_bytes + 268435456:
        fail("资料恢复事务可用空间不足，未开始外部修改")
    stage = Path(tempfile.mkdtemp(prefix="materials.recovery.", dir=recovery.parent))
    try:
        os.chmod(stage, 0o700)
        source_identities = []
        source_identities.append((projection_path, stable_copy(
            projection_path, stage / "projection.json", MAX_JSON_BYTES, 0o600)))
        source_identities.append((snapshot_path, stable_copy(
            snapshot_path, stage / "source.tar.gz", MAX_SNAPSHOT_BYTES, 0o600)))
        workspace_copy = stage / "workspace.json"
        source_identities.append((workspace_path, stable_copy(
            workspace_path, workspace_copy, MAX_JSON_BYTES, 0o600)))
        projection = read_json(stage / "projection.json")
        if projection.get("schema_version") != 2 or projection.get("state") != "applied":
            fail("只能冻结完整已应用资料代")
        observed = locations(read_json(workspace_copy, MAX_JSON_BYTES))
        workspace_copy.unlink()
        presence = {}
        for relative, (required_member, mode, maximum) in METADATA.items():
            source = safe_member(root, relative)
            exists = source.exists() or source.is_symlink()
            presence[relative] = exists
            if not exists:
                if required_member:
                    fail("旧资料代缺少必需元数据")
                continue
            destination = stage / "metadata" / relative
            make_private_parents(stage, destination.parent)
            source_identities.append((source, stable_copy(
                source, destination, maximum, mode, 1000 if mode == 0o640 else 0)))
        manifest = read_json(stage / "metadata/data/knowledge-manifest.json")
        profile = read_json(stage / "metadata/data/runtime/knowledge-profile.json", 65536) \
            if presence["data/runtime/knowledge-profile.json"] else None
        managed = profile_contract(profile, manifest)
        validate_live_bindings(root, profile, manifest)
        if capture_mode == "verified" and not set(managed).issubset(observed):
            fail("当前工作区缺少旧代受管位置，未开始资料修改")
        protected = sorted(set(observed) | set(managed))
        deletable = sorted(set(observed) & set(managed))
        missing = sorted(set(managed) - set(observed))
        content_inventory = inventory(stage)
        complete = {"schema_version": 2, "capture_mode": capture_mode, "created_at": int(time.time()),
                    "projection_sha256": file_hash(stage / "projection.json"),
                    "source_sha256": file_hash(stage / "source.tar.gz"),
                    "metadata_presence": presence, "managed_locations": managed,
                    "observed_workspace_locations": observed,
                    "protected_workspace_locations": protected,
                    "deletable_managed_locations": deletable,
                    "missing_managed_locations": missing, "inventory": content_inventory}
        atomic_json(stage / "complete.json", complete, 0o600)
        fsync_tree_directories(stage)
        validate_complete(root, stage)
        for source, identity in source_identities:
            verify_identity(source, identity)
        rename_directory_noreplace(stage, recovery)
        fsync_directory(recovery.parent)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def prepare_rebuild(root, recovery, current_workspace_path):
    current_workspace_path = controlled_input(root, current_workspace_path, "current-workspace")
    complete, _projection = validate_complete(root, recovery)
    contract = location_contract(complete)
    current = locations(read_json(current_workspace_path, MAX_JSON_BYTES))
    if set(current) - set(contract["protected"]):
        fail("工作区仍有来源未确认的新位置，拒绝重建旧代")
    garbage = contract["deletable"]
    profile_relative = "data/runtime/knowledge-profile.json"
    profile_target = safe_member(root, profile_relative)
    if complete["metadata_presence"][profile_relative]:
        source = recovery / "metadata" / profile_relative
        profile = read_json(source, 65536)
        temporary = profile_target.with_name(profile_target.name + ".restore." + uuid.uuid4().hex)
        shutil.copy2(source, temporary)
        os.chmod(temporary, 0o640)
        if os.geteuid() == 0:
            os.chown(temporary, 0, 1000)
        os.replace(temporary, profile_target)
        key = profile["fingerprint"]
    else:
        if profile_target.exists() or profile_target.is_symlink():
            if profile_target.is_symlink() or not profile_target.is_file():
                fail("候选知识 profile 类型无效")
            profile_target.unlink()
        key = ""
    manifest = {"version": 1, "files": {}, "pending_files": {}, "garbage_locations": garbage}
    if key:
        manifest["embedding_profile"] = key
    atomic_json(safe_member(root, "data/knowledge-manifest.json"), manifest, 0o600)
    atomic_json(safe_member(root, "data/knowledge-projection.json"), [], 0o600)


def build_projection(root, recovery, revision, output):
    output = controlled_input(root, output, "output")
    _complete, old = validate_complete(root, recovery)
    if revision < 1 or revision > 2147483647:
        fail("恢复投影 revision 无效")
    actual = {
        "manifest_sha256": member_hash(root, "data/knowledge-manifest.json"),
        "map_sha256": member_hash(root, "data/runtime/knowledge-map.json"),
        "settings_sha256": member_hash(root, "data/runtime/knowledge-settings.json", 65536),
        "profile_sha256": member_hash(root, "data/runtime/knowledge-profile.json", 65536)
            if safe_member(root, "data/runtime/knowledge-profile.json").is_file() else "",
        "lexical_sha256": member_hash(root, "data/runtime/knowledge-lexical.json"),
    }
    map_value = read_json(safe_member(root, "data/runtime/knowledge-map.json"))
    if map_value.get("schema_version") != 2 or not isinstance(map_value.get("documents"), list) \
            or len(map_value["documents"]) != old["knowledge"].get("enabled_document_count"):
        fail("恢复后的知识映射文档数与旧生效代不一致")
    restored = json.loads(json.dumps(old, ensure_ascii=False))
    restored["revision"] = revision
    restored["state"] = "applied"
    restored["applied_at"] = int(time.time())
    restored["configuration"]["runtime"]["revision"] = revision
    restored["configuration"]["runtime"]["applied_revision"] = revision
    restored["knowledge"].update(actual)
    restored["source_components"]["knowledge"] = value_hash(restored["knowledge"])
    restored["source_sha256"] = value_hash(restored["source_components"])
    atomic_json(output, restored, 0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deploy-dir", required=True)
    parser.add_argument("--recovery", required=True)
    commands = parser.add_subparsers(dest="action", required=True)
    capture_command = commands.add_parser("capture")
    capture_command.add_argument("--projection", required=True)
    capture_command.add_argument("--snapshot", required=True)
    capture_command.add_argument("--workspace-locations", required=True)
    capture_command.add_argument("--capture-mode", choices=("verified", "external_repair"), required=True)
    commands.add_parser("validate")
    rebuild = commands.add_parser("prepare-rebuild")
    rebuild.add_argument("--current-workspace-locations", required=True)
    build = commands.add_parser("build-projection")
    build.add_argument("--revision", required=True, type=int)
    build.add_argument("--output", required=True)
    commands.add_parser("baseline-locations")
    commands.add_parser("managed-locations")
    commands.add_parser("observed-locations")
    commands.add_parser("protected-locations")
    commands.add_parser("deletable-locations")
    commands.add_parser("missing-locations")
    commands.add_parser("missing-projections")
    commands.add_parser("repair-scope")
    commands.add_parser("classify-delete")
    commands.add_parser("record-touched")
    commands.add_parser("write-cleanup")
    commands.add_parser("settle-cleanup")
    commands.add_parser("finish-upload")
    commands.add_parser("finish-tracking")
    begin = commands.add_parser("begin-upload")
    begin.add_argument("--filename", required=True)
    begin.add_argument("--source", required=True)
    commands.add_parser("resolve-upload")
    commands.add_parser("cleanup-upload-orphan")
    commands.add_parser("cleanup-orphans")
    commands.add_parser("retire")
    commands.add_parser("cleanup-retired")
    args = parser.parse_args()
    root = safe_root(args.deploy_dir)
    recovery = recovery_root(root, args.recovery)
    if args.action == "capture":
        capture(root, recovery, Path(args.projection), Path(args.snapshot), Path(args.workspace_locations),
                args.capture_mode)
    elif args.action == "validate":
        validate_complete(root, recovery)
    elif args.action == "prepare-rebuild":
        prepare_rebuild(root, recovery, Path(args.current_workspace_locations))
    elif args.action == "build-projection":
        build_projection(root, recovery, args.revision, Path(args.output))
    elif args.action in ("baseline-locations", "managed-locations", "observed-locations",
                         "protected-locations", "deletable-locations", "missing-locations",
                         "missing-projections"):
        complete, _projection = validate_complete(root, recovery)
        contract = location_contract(complete)
        if args.action == "baseline-locations":
            value = contract["protected"]
        elif args.action == "managed-locations":
            value = contract["managed"]
        elif args.action == "observed-locations":
            value = contract["observed"]
        elif args.action == "protected-locations":
            value = contract["protected"]
        elif args.action == "deletable-locations":
            value = contract["deletable"]
        elif args.action == "missing-locations":
            value = contract["missing"]
        else:
            value = [item["projection"] for item in repair_scope(root, recovery)["projections"]]
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    elif args.action == "repair-scope":
        print(json.dumps(repair_scope(root, recovery), ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    elif args.action == "classify-delete":
        print(json.dumps(classify_delete(root, recovery, stdin_locations()), ensure_ascii=False,
                         sort_keys=True, separators=(",", ":")))
    elif args.action == "record-touched":
        record_touched(root, recovery, stdin_locations())
    elif args.action == "write-cleanup":
        write_cleanup(root, recovery, stdin_locations())
    elif args.action == "settle-cleanup":
        settle_cleanup(root, recovery, stdin_locations())
    elif args.action == "finish-upload":
        finish_upload(root, recovery)
    elif args.action == "finish-tracking":
        finish_tracking(root, recovery)
    elif args.action == "begin-upload":
        print(json.dumps(begin_upload(root, recovery, args.filename, args.source), ensure_ascii=False, separators=(",", ":")))
    elif args.action == "resolve-upload":
        print(json.dumps(resolve_upload(root, recovery), ensure_ascii=False, separators=(",", ":")))
    elif args.action == "cleanup-upload-orphan":
        print(json.dumps({"ok": True, "action": args.action, "cleaned": cleanup_upload_orphan(recovery)},
                         ensure_ascii=False))
    elif args.action == "cleanup-orphans":
        print(json.dumps({"ok": True, "action": args.action,
                          "removed": cleanup_sibling_orphans(recovery)}, ensure_ascii=False))
    elif args.action == "retire":
        print(json.dumps({"ok": True, "action": args.action, "cleaned": retire(root, recovery)}, ensure_ascii=False))
    elif args.action == "cleanup-retired":
        print(json.dumps({"ok": True, "action": args.action, "cleaned": cleanup_retired(recovery)}, ensure_ascii=False))
    if args.action not in ("baseline-locations", "managed-locations", "observed-locations",
                           "protected-locations", "deletable-locations", "missing-locations",
                           "missing-projections", "repair-scope", "classify-delete",
                           "begin-upload", "resolve-upload",
                           "cleanup-upload-orphan", "cleanup-orphans", "retire", "cleanup-retired"):
        print(json.dumps({"ok": True, "action": args.action}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except RecoveryError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, MemoryError, RecursionError):
        print("资料恢复事务失败；旧代保全保持不变，自动回复继续受阻止。", file=sys.stderr)
        sys.exit(1)
