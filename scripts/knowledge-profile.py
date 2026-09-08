#!/usr/bin/env python3
"""受管知识索引代次与停止状态下的组件保全；不读取/恢复客服会话。"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import time
import uuid

MODELS = {
    "Xenova/all-MiniLM-L6-v2": ("", ""),
    "Xenova/nomic-embed-text-v1": ("search_document: ", "search_query: "),
    "MintplexLabs/multilingual-e5-small": ("passage: ", "query: "),
}
MAX_METADATA_BYTES = 512 * 1024 * 1024
MAX_MANIFEST_BYTES = 16 * 1024 * 1024
METADATA = ("data/knowledge-manifest.json", "data/runtime/knowledge-profile.json",
            "data/knowledge-projection.json", "data/runtime/knowledge-map.json",
            "data/runtime/knowledge-settings.json", "data/runtime/knowledge-lexical.json",
            "knowledge/catalog.json", "config/materials-applied.json")


class KnowledgeError(Exception):
    pass


def fail(message):
    raise KnowledgeError(message)


def safe_path(root, relative):
    if root.is_symlink():
        fail("受管知识路径根目录不能是符号链接")
    parts = PurePosixPath(relative).parts
    if not parts or relative.startswith("/") or ".." in parts or any(ord(c) < 32 for c in relative):
        fail("受管知识路径不安全")
    path = root
    for part in parts:
        path /= part
        if path.is_symlink():
            fail("受管知识路径不能包含符号链接")
    return path


def read(path, fallback=None, maximum=MAX_METADATA_BYTES):
    if not path.exists():
        return fallback
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        fail("知识元数据文件类型或大小无效")
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def atomic(path, value, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        if os.geteuid() == 0 and mode == 0o640:
            os.chown(name, 0, 1000)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            value.update(chunk)
    return value.hexdigest()


def profile(observed, model=None, size=None):
    if not isinstance(observed, dict) or observed.get("engine") != "native":
        fail("当前不是受管 Native Embedding，不能自动替换")
    model = model or observed.get("model")
    size = observed.get("chunk_size") if size is None else size
    overlap = observed.get("chunk_overlap")
    maximum = 16000 if model == "Xenova/nomic-embed-text-v1" else 1000
    if model not in MODELS or type(size) is not int or not 1 <= size <= maximum or type(overlap) is not int or not 0 <= overlap < size:
        fail("知识模型或分块参数无效")
    if observed.get("component_version") != "1.16.1":
        fail("知识组件版本尚未验证，拒绝执行自动模型迁移")
    passage, query = MODELS[model]
    return {"engine": "native", "model": model, "chunk_size": size,
            "chunk_overlap": overlap, "passage_prefix": passage, "query_prefix": query,
            "component_version": "1.16.1", "splitter": "AnythingLLM-1.16.1-TextSplitter"}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def cache_path(root, location):
    if not isinstance(location, str) or "\\" in location or not location.endswith(".json") or len(location.encode("utf-8")) > 1024:
        fail("知识文档索引位置无效")
    parsed = PurePosixPath(location)
    if parsed.is_absolute() or len(parsed.parts) != 2 or parsed.parts[0] != "custom-documents" \
            or any(part in ("", ".", "..") for part in parsed.parts) or any(ord(c) < 32 for c in location):
        fail("知识文档索引位置无效")
    safe_path(root, "data/anythingllm/documents/" + location)
    return safe_path(root, "data/anythingllm/vector-cache/" + str(uuid.uuid5(uuid.NAMESPACE_URL, location)) + ".json")


def scan_tree(path):
    if path.is_symlink() or not path.is_dir():
        fail("组件保全根目录必须是普通目录")
    total = 0
    count = 0
    for base, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            child = Path(base) / name
            status = child.lstat()
            if stat.S_ISLNK(status.st_mode) or not (stat.S_ISREG(status.st_mode) or stat.S_ISDIR(status.st_mode)):
                fail("组件保全遇到链接或特殊文件，未继续")
            if stat.S_ISREG(status.st_mode) and status.st_nlink != 1:
                fail("组件保全遇到硬链接，未继续")
            count += 1
            if count > 250000:
                fail("组件保全文件数量超出上限")
            if stat.S_ISREG(status.st_mode):
                total += status.st_size
    return total


def tree_inventory(path):
    scan_tree(path)
    root_info = path.lstat()
    result = [{"path": ".", "type": "directory", "mode": stat.S_IMODE(root_info.st_mode),
               "uid": root_info.st_uid, "gid": root_info.st_gid}]
    for child in sorted(path.rglob("*"), key=lambda item: os.fsencode(str(item.relative_to(path)))):
        info = child.lstat()
        relative = child.relative_to(path).as_posix()
        record = {"path": relative, "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}
        if stat.S_ISDIR(info.st_mode):
            record["type"] = "directory"
        elif stat.S_ISREG(info.st_mode):
            record.update({"type": "file", "size": info.st_size, "sha256": digest(child)})
        else:
            fail("组件保全清单遇到链接或特殊文件")
        result.append(record)
    return result


def metadata_record(path):
    if path.is_symlink() or not path.is_file():
        fail("知识保全元数据不是普通文件")
    info = path.stat()
    return {"size": info.st_size, "sha256": digest(path), "mode": stat.S_IMODE(info.st_mode),
            "uid": info.st_uid, "gid": info.st_gid}


def validate_backup(backup, plan):
    if backup.is_symlink() or not backup.is_dir():
        fail("知识组件保全目录无效")
    complete = read(backup / "complete.json")
    saved_plan = read(backup / "plan.json")
    if not isinstance(complete, dict) or complete.get("schema_version") != 1 \
            or saved_plan != plan or complete.get("plan_sha256") != digest(backup / "plan.json"):
        fail("知识组件保全计划不完整或已改变")
    expected_inventory = complete.get("anythingllm_inventory")
    if not isinstance(expected_inventory, list) or tree_inventory(backup / "anythingllm") != expected_inventory:
        fail("知识组件保全内容不完整或已改变")
    names = complete.get("metadata")
    records = complete.get("metadata_records")
    if not isinstance(names, list) or len(names) != len(set(names)) or not isinstance(records, dict) or set(names) != set(records):
        fail("知识组件保全元数据清单无效")
    for relative in names:
        if relative not in METADATA or metadata_record(safe_path(backup / "metadata", relative)) != records[relative]:
            fail("知识组件保全元数据不完整或已改变")
    return complete


def current_profile_complete(root, current, key):
    if not isinstance(current, dict) or current.get("state") != "applied" or current.get("fingerprint") != key:
        return False
    if not isinstance(current.get("profile"), dict) or fingerprint(current["profile"]) != key:
        return False
    try:
        manifest, manifest_identity = decode_stable_json(
            safe_path(root, "data/knowledge-manifest.json"), MAX_MANIFEST_BYTES)
        if manifest.get("embedding_profile") != key or manifest.get("pending_files") or manifest.get("garbage_locations"):
            return False
        snapshots = []
        for record in manifest.get("files", {}).values():
            if record.get("embedding_profile") != key or not record.get("locations"):
                return False
            raw_bindings = record.get("cache_bindings")
            if not isinstance(raw_bindings, list) or len(raw_bindings) != len(record["locations"]):
                return False
            bindings = {item.get("location"): item.get("sha256") for item in raw_bindings
                        if isinstance(item, dict) and isinstance(item.get("location"), str)
                        and isinstance(item.get("sha256"), str)}
            if set(bindings) != set(record["locations"]) or len(bindings) != len(raw_bindings):
                return False
            for location in record["locations"]:
                cached = cache_path(root, location)
                cache_digest, cache_identity = stable_digest(cached)
                if bindings[location] != cache_digest:
                    return False
                snapshots.append((cached, cache_identity))
        verify_identity(safe_path(root, "data/knowledge-manifest.json"), manifest_identity)
        for cached, cache_identity in snapshots:
            verify_identity(cached, cache_identity)
    except (AttributeError, TypeError, KnowledgeError, OSError):
        return False
    return True


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def stable_file(path, maximum=None, empty=False):
    """不跟随叶子链接，读取前后身份一致才返回；FIFO 用 NONBLOCK 拒绝而不挂起。"""
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or (not empty and before.st_size == 0) \
                or maximum is not None and before.st_size > maximum:
            fail("知识缓存或元数据文件类型、大小或链接状态无效")
        chunks, size = [], 0
        while True:
            chunk = os.read(descriptor, 1048576)
            if not chunk:
                break
            size += len(chunk)
            if maximum is not None and size > maximum:
                fail("知识缓存或元数据文件大小无效")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        if size != before.st_size or file_identity(after) != file_identity(before):
            fail("知识缓存或元数据在读取期间发生变化")
        return b"".join(chunks), file_identity(before)
    except (FileNotFoundError, OSError):
        fail("知识缓存或元数据文件缺失或不安全")
    finally:
        if descriptor is not None:
            os.close(descriptor)


def stable_digest(path):
    """流式计算可能较大的向量缓存，避免为一次绑定把整份文件读入内存。"""
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size == 0:
            fail("知识缓存文件类型、大小或链接状态无效")
        value, size = hashlib.sha256(), 0
        while True:
            chunk = os.read(descriptor, 1048576)
            if not chunk:
                break
            size += len(chunk)
            value.update(chunk)
        after = os.fstat(descriptor)
        if size != before.st_size or file_identity(after) != file_identity(before):
            fail("知识缓存文件在读取期间发生变化")
        return value.hexdigest(), file_identity(before)
    except (FileNotFoundError, OSError):
        fail("知识缓存文件缺失或不安全")
    finally:
        if descriptor is not None:
            os.close(descriptor)


def verify_identity(path, expected, empty=False):
    try:
        info = path.lstat()
    except OSError:
        fail("知识缓存或元数据在对账期间发生变化")
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or (not empty and info.st_size == 0) \
            or file_identity(info) != expected:
        fail("知识缓存或元数据在对账期间发生变化")


def decode_stable_json(path, maximum):
    raw, identity = stable_file(path, maximum)
    try:
        return json.loads(raw.decode("utf-8", "strict")), identity
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        fail("知识缓存或元数据 JSON 无效")


def checked_migration_pointer(root, migration_path):
    pointer, _ = decode_stable_json(migration_path, 65536)
    if not isinstance(pointer, dict) or set(pointer) != {"schema_version", "backup"} \
            or pointer.get("schema_version") != 1 or not isinstance(pointer.get("backup"), str) \
            or not pointer["backup"]:
        fail("知识索引迁移记录无效，未刷新缓存绑定")
    backup = Path(pointer["backup"])
    expected_parent = safe_path(root, "backups/knowledge-profiles")
    if not backup.is_absolute() or backup.parent != expected_parent or not backup.name.startswith("generation.") \
            or backup.is_symlink() or not backup.is_dir():
        fail("知识索引迁移保全位置无效，未刷新缓存绑定")
    return pointer


def refresh_bindings(root, allow_migration=False, validate_only=False, require_complete=False):
    """核对旧摘要，并仅为同步后没有摘要的文档原子补齐缓存绑定。"""
    profile_path = safe_path(root, "data/runtime/knowledge-profile.json")
    manifest_path = safe_path(root, "data/knowledge-manifest.json")
    migration_path = safe_path(root, "data/runtime/knowledge-migration.json")
    current, profile_identity = decode_stable_json(profile_path, 65536)
    if not isinstance(current, dict) or current.get("schema_version") != 1 \
            or not isinstance(current.get("profile"), dict) \
            or current.get("fingerprint") != fingerprint(current["profile"]):
        fail("知识索引代次无效，未刷新缓存绑定")
    key = current["fingerprint"]
    state = current.get("state")
    if state == "applying":
        if not allow_migration or not migration_path.exists():
            fail("知识索引处于未登记的迁移状态，未刷新缓存绑定")
        checked_migration_pointer(root, migration_path)
        return {"success": True, "action": "refresh-bindings", "changed": False,
                "skipped": True, "reason": "migration_in_progress", "bindings": 0}
    if state != "applied":
        fail("知识索引迁移尚未完成，未刷新缓存绑定")
    if migration_path.exists():
        if not allow_migration:
            fail("知识索引迁移尚未完成，未刷新缓存绑定")
        checked_migration_pointer(root, migration_path)
        if not current_profile_complete(root, current, key):
            fail("知识索引迁移提交后的缓存绑定尚未完整，未跳过刷新")
        return {"success": True, "action": "refresh-bindings", "changed": False,
                "skipped": True, "reason": "migration_committed", "bindings": 0}

    if require_complete:
        if not validate_only or allow_migration or not current_profile_complete(root, current, key):
            fail("知识索引代次、manifest 或缓存绑定未完整应用")
        manifest = read(manifest_path, {}, MAX_MANIFEST_BYTES)
        return {"success": True, "action": "refresh-bindings", "changed": False,
                "skipped": False, "reason": "complete_validation_only",
                "bindings": sum(len(record.get("cache_bindings", []))
                                for record in manifest.get("files", {}).values()
                                if isinstance(record, dict))}

    manifest, manifest_identity = decode_stable_json(manifest_path, MAX_MANIFEST_BYTES)
    if not isinstance(manifest, dict) or manifest.get("version") != 1 \
            or not isinstance(manifest.get("files"), dict) \
            or manifest.get("embedding_profile") != key \
            or not isinstance(manifest.get("pending_files"), dict) \
            or not isinstance(manifest.get("garbage_locations"), list):
        fail("知识 manifest 尚未完整对账，未刷新缓存绑定")
    if not validate_only and (manifest.get("pending_files") != {} or manifest.get("garbage_locations") != []):
        fail("知识 manifest 尚未完整对账，未刷新缓存绑定")

    candidate = json.loads(json.dumps(manifest, ensure_ascii=False))
    snapshots = []
    seen_locations = set()
    binding_count = 0
    for name, record in candidate["files"].items():
        if not isinstance(name, str) or not name or "\0" in name or not isinstance(record, dict) \
                or not isinstance(record.get("sha256"), str) or len(record["sha256"]) != 64 \
                or any(character not in "0123456789abcdef" for character in record["sha256"]) \
                or record.get("embedding_profile") != key:
            fail("知识 manifest 文档记录无效，未刷新缓存绑定")
        locations = record.get("locations")
        if not isinstance(locations, list) or not locations or len(locations) != len(set(locations)) \
                or any(location in seen_locations for location in locations):
            fail("知识 manifest 文档位置无效或重复，未刷新缓存绑定")
        raw_bindings = record.get("cache_bindings")
        if raw_bindings not in (None, []):
            if not isinstance(raw_bindings, list) or len(raw_bindings) != len(locations):
                fail("知识 manifest 缓存绑定无效，未刷新缓存绑定")
            bindings = {}
            for item in raw_bindings:
                if not isinstance(item, dict) or set(item) != {"location", "sha256"} \
                        or not isinstance(item.get("location"), str) \
                        or not isinstance(item.get("sha256"), str) \
                        or len(item["sha256"]) != 64 \
                        or any(character not in "0123456789abcdef" for character in item["sha256"]) \
                        or item["location"] in bindings:
                    fail("知识 manifest 缓存绑定无效，未刷新缓存绑定")
                bindings[item["location"]] = item["sha256"]
            if set(bindings) != set(locations):
                fail("知识 manifest 缓存绑定无效，未刷新缓存绑定")
            for location in locations:
                cached = cache_path(root, location)
                cache_digest, cache_identity = stable_digest(cached)
                if cache_digest != bindings[location]:
                    fail("知识缓存与已有绑定不一致，拒绝重新签署")
                snapshots.append((cached, cache_identity))
                seen_locations.add(location)
                binding_count += 1
        elif validate_only:
            seen_locations.update(locations)
        else:
            bindings = []
            for location in locations:
                cached = cache_path(root, location)
                cache_digest, cache_identity = stable_digest(cached)
                bindings.append({"location": location, "sha256": cache_digest})
                snapshots.append((cached, cache_identity))
                seen_locations.add(location)
                binding_count += 1
            record["cache_bindings"] = bindings

    # Shell 调用方持有实例维护锁；这里仍复核所有输入身份，防止外部进程绕锁改出混合快照。
    verify_identity(profile_path, profile_identity)
    verify_identity(manifest_path, manifest_identity)
    if migration_path.exists() or migration_path.is_symlink():
        fail("知识索引迁移在缓存对账期间开始，未刷新缓存绑定")
    for cached, cache_identity in snapshots:
        verify_identity(cached, cache_identity)
    if validate_only:
        return {"success": True, "action": "refresh-bindings", "changed": False,
                "skipped": False, "reason": "validation_only", "bindings": binding_count}
    changed = candidate != manifest
    if changed:
        atomic(manifest_path, candidate)
    if not current_profile_complete(root, current, key):
        fail("知识缓存绑定写入后未通过完整回读")
    return {"success": True, "action": "refresh-bindings", "changed": changed,
            "skipped": False, "reason": None, "bindings": binding_count}


def copy_preserving(source, target):
    if source.is_dir():
        shutil.copytree(source, target, copy_function=shutil.copy2)
        paths = [source] + list(source.rglob("*"))
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        paths = [source]
    if os.geteuid() == 0:
        for path in paths:
            info = path.stat()
            copied = target if path == source else target / path.relative_to(source)
            os.chown(copied, info.st_uid, info.st_gid)


def main():
    parser = argparse.ArgumentParser(description="知识模型和索引代次的受管维护")
    parser.add_argument("--deploy-dir", required=True)
    parser.add_argument("action", choices=("plan", "backup", "activate", "commit", "restore", "status", "refresh-bindings"))
    parser.add_argument("--observed")
    parser.add_argument("--model")
    parser.add_argument("--chunk-size", type=int)
    parser.add_argument("--plan")
    parser.add_argument("--backup")
    parser.add_argument("--allow-migration", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--validate-only", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--require-complete", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    root = Path(args.deploy_dir).absolute()
    if str(root) in ("/", "/root", "/opt", "/tmp") or root.resolve() != root or not root.is_dir():
        fail("部署目录无效")
    target = safe_path(root, "data/runtime/knowledge-profile.json")
    current = read(target)
    if args.action == "refresh-bindings":
        print(json.dumps(refresh_bindings(root, args.allow_migration, args.validate_only,
                                          args.require_complete), ensure_ascii=False))
        return
    if args.allow_migration or args.validate_only or args.require_complete:
        fail("迁移内部门禁参数只能用于刷新缓存绑定")
    if args.action in ("plan", "status"):
        observed = read(Path(args.observed)) if args.observed else None
        if args.action == "status" and observed is None:
            print(json.dumps({"configured": current is not None, "state": (current or {}).get("state", "unknown")}))
            return
        candidate = profile(observed, args.model, args.chunk_size)
        key = fingerprint(candidate)
        changed = profile(observed) != candidate or not current_profile_complete(root, current, key)
        if profile(observed) != candidate and observed.get("foreign_documents", 0):
            fail("组件含非本工作区索引，不能自动更换全局 Embedding")
        manifest = read(safe_path(root, "data/knowledge-manifest.json"), {}, MAX_MANIFEST_BYTES)
        managed_count = len({location for record in manifest.get("files", {}).values() for location in record.get("locations", [])})
        workspace_count = observed.get("workspace_documents")
        if profile(observed) != candidate and (type(workspace_count) is not int or workspace_count != managed_count):
            fail("目标工作区含未受管文档或索引映射不完整，不能自动更换全局 Embedding")
        result = {"schema_version": 1, "profile": candidate, "fingerprint": key,
                  "requires_reindex": changed, "previous_model": observed["model"]}
        print(json.dumps(result, ensure_ascii=False))
        return
    if not args.backup:
        fail("缺少受管保全目录")
    backup = Path(args.backup).absolute()
    if backup.parent != safe_path(root, "backups/knowledge-profiles") or backup.is_symlink() or not backup.name.startswith("generation."):
        fail("知识保全目录不安全")
    plan = read(Path(args.plan)) if args.plan else read(backup / "plan.json")
    if not isinstance(plan, dict) or fingerprint(plan.get("profile")) != plan.get("fingerprint"):
        fail("知识迁移计划校验失败")
    storage = safe_path(root, "data/anythingllm")
    if args.action == "backup":
        if not storage.is_dir() or backup.exists() and any(backup.iterdir()):
            fail("知识组件或保全目录状态无效")
        size = scan_tree(storage)
        if shutil.disk_usage(root).free < 2 * size + 2147483648:
            fail("知识模型迁移保全空间不足，未改索引")
        backup.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(backup, 0o700)
        atomic(backup / "plan.json", plan)
        copy_preserving(storage, backup / "anythingllm")
        saved = []
        records = {}
        for relative in METADATA:
            source = safe_path(root, relative)
            if source.exists():
                if not source.is_file():
                    fail("知识保全元数据不是普通文件")
                copy_preserving(source, backup / "metadata" / relative)
                saved.append(relative)
                records[relative] = metadata_record(backup / "metadata" / relative)
        atomic(backup / "complete.json", {"schema_version": 1, "created_at": int(time.time()), "metadata": saved,
               "metadata_records": records, "plan_sha256": digest(backup / "plan.json"),
               "anythingllm_inventory": tree_inventory(backup / "anythingllm")})
    elif args.action == "activate":
        validate_backup(backup, plan)
        manifest_path = safe_path(root, "data/knowledge-manifest.json")
        manifest = read(manifest_path, {"version": 1, "files": {}, "pending_files": {}, "garbage_locations": []},
                        MAX_MANIFEST_BYTES)
        locations = set(manifest.get("garbage_locations", []))
        for group in (manifest.get("files", {}), manifest.get("pending_files", {})):
            for record in group.values():
                locations.update(record.get("locations", []))
        cache_backup = backup / "quarantined-cache"
        cache_backup.mkdir(mode=0o700, exist_ok=True)
        for location in locations:
            cached = cache_path(root, location)
            if cached.exists():
                if not cached.is_file() or (cache_backup / cached.name).exists():
                    fail("向量缓存隔离目标冲突")
                os.replace(cached, cache_backup / cached.name)
        garbage = set(manifest.get("garbage_locations", []))
        for record in manifest.get("pending_files", {}).values():
            garbage.update(record.get("locations", []))
        manifest["pending_files"] = {}
        manifest["garbage_locations"] = sorted(garbage)
        manifest["embedding_profile"] = plan["fingerprint"]
        atomic(manifest_path, manifest)
        atomic(target, {**plan, "state": "applying", "started_at": int(time.time())}, 0o640)
    elif args.action == "commit":
        validate_backup(backup, plan)
        active, active_identity = decode_stable_json(target, 65536)
        if not isinstance(active, dict) or active.get("state") != "applying" or active.get("fingerprint") != plan["fingerprint"] \
                or active.get("profile") != plan["profile"]:
            fail("当前知识索引不是本次迁移的受阻止代次")
        observed_path = Path(args.observed)
        observed, observed_identity = decode_stable_json(observed_path, 65536)
        if profile(observed) != plan["profile"]:
            fail("实际知识模型或分块与候选不一致")
        manifest_path = safe_path(root, "data/knowledge-manifest.json")
        manifest, manifest_identity = decode_stable_json(manifest_path, MAX_MANIFEST_BYTES)
        if not manifest or manifest.get("embedding_profile") != plan["fingerprint"] or manifest.get("pending_files") or manifest.get("garbage_locations"):
            fail("知识索引尚有未对账项目，不能声明迁移完成")
        snapshots = []
        for record in manifest["files"].values():
            if record.get("embedding_profile") != plan["fingerprint"] or not record.get("locations"):
                fail("知识文档仍属于旧索引代次")
            record["cache_bindings"] = []
            for location in record["locations"]:
                cached = cache_path(root, location)
                cache_digest, cache_identity = stable_digest(cached)
                record["cache_bindings"].append({"location": location, "sha256": cache_digest})
                snapshots.append((cached, cache_identity))
        # 所有输入在摘要形成后仍须保持同一普通单链接 inode；先发布 manifest，
        # 再次复核其内容和缓存，最后才允许将 profile 从 applying 标记为 applied。
        verify_identity(target, active_identity)
        verify_identity(observed_path, observed_identity)
        verify_identity(manifest_path, manifest_identity)
        for cached, cache_identity in snapshots:
            verify_identity(cached, cache_identity)
        atomic(manifest_path, manifest)
        published, published_identity = decode_stable_json(manifest_path, MAX_MANIFEST_BYTES)
        if published != manifest:
            fail("知识 manifest 发布后回读不一致，未提交索引代次")
        verify_identity(target, active_identity)
        verify_identity(observed_path, observed_identity)
        verify_identity(manifest_path, published_identity)
        for cached, cache_identity in snapshots:
            verify_identity(cached, cache_identity)
        atomic(target, {**plan, "state": "applied", "applied_at": int(time.time())}, 0o640)
    elif args.action == "restore":
        active = read(target)
        if isinstance(active, dict) and active.get("state") == "applying" \
                and (active.get("fingerprint") != plan["fingerprint"] or active.get("profile") != plan["profile"]):
            fail("当前存在另一份知识索引迁移，拒绝交叉恢复")
        complete = validate_backup(backup, plan)
        # 在触碰当前组件前复制并再次核对候选；损坏备份不能先替换可运行目录。
        restored = Path(tempfile.mkdtemp(prefix=".anythingllm-restore.", dir=storage.parent))
        restored.rmdir()
        copy_preserving(backup / "anythingllm", restored)
        if tree_inventory(restored) != complete["anythingllm_inventory"]:
            shutil.rmtree(restored)
            fail("知识组件恢复候选复制不完整")
        candidates = {}
        for relative in complete["metadata"]:
            if relative == "config/materials-applied.json":
                continue
            source = safe_path(backup / "metadata", relative)
            destination = safe_path(root, relative)
            candidate = destination.with_name(destination.name + ".restore." + uuid.uuid4().hex)
            copy_preserving(source, candidate)
            if metadata_record(candidate) != complete["metadata_records"][relative]:
                candidate.unlink(missing_ok=True)
                shutil.rmtree(restored)
                fail("知识元数据恢复候选复制不完整")
            candidates[relative] = candidate
        rejected = Path(tempfile.mkdtemp(prefix="anythingllm-rejected.", dir=backup))
        rejected.rmdir()
        os.replace(storage, rejected)
        os.replace(restored, storage)
        for relative in METADATA:
            # 只恢复索引元数据；资料投影由 Shell 提升代次后恢复，绝不恢复 data/runtime 会话目录。
            if relative == "config/materials-applied.json":
                continue
            destination = safe_path(root, relative)
            if relative in complete["metadata"]:
                os.replace(candidates[relative], destination)
            elif destination.exists():
                os.replace(destination, backup / ("rejected-" + relative.replace("/", "_")))
    print(json.dumps({"success": True, "action": args.action}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except KnowledgeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError):
        print("知识索引代次维护失败；原保全资料保留，请检查组件、格式和可用空间。", file=sys.stderr)
        sys.exit(1)
