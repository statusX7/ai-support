#!/usr/bin/env python3
"""受限生命周期夹具：模拟当前 AnythingLLM 实例的解析正文与向量缓存。"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import stat
import sys
import urllib.parse
import uuid


def fail():
    raise SystemExit(1)


def directory_fd(path):
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in Path(os.path.abspath(path)).parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def validate_scope(path):
    value = Path(path)
    repository = Path(__file__).resolve().parents[2]
    if not value.is_absolute():
        fail()
    try:
        relative = value.relative_to(repository)
    except ValueError:
        fail()
    if not relative.parts or not relative.parts[0].startswith(".test-runtime.") \
            or relative.parts[0] == ".test-runtime.":
        fail()
    current = repository
    for index, part in enumerate(relative.parts):
        if part in ("", ".", ".."):
            fail()
        current /= part
        info = os.lstat(current)
        mode = stat.S_IMODE(info.st_mode)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) \
                or info.st_uid != os.geteuid() or mode & 0o022:
            fail()
        if index in (0, len(relative.parts) - 1) and mode != 0o700:
            fail()
    return str(value)


def open_child_directories(descriptor, parts, create=False):
    current = os.dup(descriptor)
    try:
        for part in parts:
            if part in ("", ".", "..") or "/" in part or "\0" in part:
                fail()
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=current)
            except FileNotFoundError:
                if not create:
                    os.close(current)
                    return None
                os.mkdir(part, 0o755, dir_fd=current)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=current)
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise


def stable_read_at(root_fd, relative, maximum):
    if isinstance(relative, (tuple, list)):
        parts = tuple(relative)
    else:
        parts = Path(relative).parts
    if not parts:
        fail()
    if any(part in ("", ".", "..") or "/" in part or "\0" in part for part in parts):
        fail()
    parent = open_child_directories(root_fd, parts[:-1])
    if parent is None:
        fail()
    descriptor = None
    try:
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=parent)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum:
            fail()
        chunks, total = [], 0
        while True:
            chunk = os.read(descriptor, min(1048576, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                fail()
        after = os.fstat(descriptor)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
                                  value.st_uid, value.st_gid, value.st_size,
                                  value.st_mtime_ns, value.st_ctime_ns)
        if total != before.st_size or identity(after) != identity(before):
            fail()
        return b"".join(chunks)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def relative_to_scope(scope, path):
    scope_value = os.path.abspath(scope)
    path_value = os.path.abspath(path)
    try:
        if os.path.commonpath((scope_value, path_value)) != scope_value:
            fail()
    except ValueError:
        fail()
    relative = os.path.relpath(path_value, scope_value)
    if relative == "." or relative.startswith(".." + os.sep):
        fail()
    return Path(relative).parts


def is_within(scope, path):
    try:
        return os.path.commonpath((os.path.abspath(scope), os.path.abspath(path))) == os.path.abspath(scope) \
            and os.path.abspath(scope) != os.path.abspath(path)
    except ValueError:
        return False


def authorization_digest(raw):
    headers = []
    for line in raw.decode("utf-8", "strict").splitlines():
        key, separator, value = line.partition("=")
        if separator and key.strip() == "header":
            headers.append(json.loads(value.strip()))
    values = [header[len("Authorization: Bearer "):] for header in headers
              if isinstance(header, str) and header.startswith("Authorization: Bearer ")]
    if len(values) != 1 or not values[0] or "\n" in values[0] or "\r" in values[0]:
        fail()
    return hashlib.sha256(values[0].encode()).hexdigest()


def parse_project_config(project_fd, project, config):
    parts = relative_to_scope(project, config)
    raw = stable_read_at(project_fd, parts, 65536)
    return authorization_digest(raw)


def parse_doctor_config(config):
    value = Path(config)
    parent = value.parent
    if not value.is_absolute() or parent.parent != Path("/tmp") \
            or not parent.name.startswith("crispai-doctor.") or value.name != "anything-workspace.conf":
        fail()
    parent_info = os.lstat(parent)
    if not stat.S_ISDIR(parent_info.st_mode) or stat.S_ISLNK(parent_info.st_mode) \
            or parent_info.st_uid != os.geteuid() or stat.S_IMODE(parent_info.st_mode) != 0o700:
        fail()
    parent_fd = directory_fd(parent)
    try:
        before = os.stat(value.name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 \
                or before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) != 0o600:
            fail()
        raw = stable_read_at(parent_fd, (value.name,), 65536)
        after = os.stat(value.name, dir_fd=parent_fd, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_nlink,
                                 item.st_uid, item.st_gid, item.st_size,
                                 item.st_mtime_ns, item.st_ctime_ns)
        if identity(before) != identity(after):
            fail()
        return authorization_digest(raw)
    finally:
        os.close(parent_fd)


def verify_instance(state, url, digest, scope, project):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost") \
            or parsed.username or parsed.password or not parsed.port:
        fail()
    instances = state.get("rag_instances")
    if not isinstance(instances, dict):
        fail()
    project = os.path.abspath(project)
    relative_to_scope(scope, project)
    value = instances.get(project)
    if not isinstance(value, dict) or value.get("port") != parsed.port \
            or value.get("api_key_sha256") != digest:
        fail()
    return project


def safe_location(value):
    if not isinstance(value, str) or len(value.encode("utf-8")) > 1024 \
            or "\\" in value or any(ord(character) < 32 or ord(character) == 127 for character in value):
        fail()
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or len(parsed.parts) != 2 or parsed.parts[0] != "custom-documents" \
            or any(part in ("", ".", "..") for part in parsed.parts) or not value.endswith(".json"):
        fail()
    return parsed


def target(parent, leaf, raw=None):
    try:
        info = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        info = None
    if info is not None and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
        fail()
    return {"parent": parent, "leaf": leaf, "raw": raw}


def publish(item):
    temporary = ".mock-cache-" + secrets.token_hex(16) + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=item["parent"])
    try:
        os.fchmod(descriptor, 0o600)
        if os.geteuid() == 0:
            os.fchown(descriptor, 1000, 1000)
        view = memoryview(item["raw"])
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                fail()
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary, item["leaf"], src_dir_fd=item["parent"], dst_dir_fd=item["parent"])
        os.fsync(item["parent"])
    finally:
        try:
            os.unlink(temporary, dir_fd=item["parent"])
        except FileNotFoundError:
            pass


def publish_state(scope_fd, relative, value):
    parts = tuple(relative)
    parent = open_child_directories(scope_fd, parts[:-1])
    if parent is None:
        fail()
    temporary = ".mock-state-" + secrets.token_hex(16) + ".tmp"
    descriptor = None
    try:
        info = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail()
        raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=parent)
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                fail()
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, parts[-1], src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def main():
    if len(sys.argv) < 6 or sys.argv[1] not in ("upload", "remove", "update", "observe"):
        fail()
    action, state_name, scope, url, config = sys.argv[1:6]
    scope = validate_scope(scope)
    scope_fd = directory_fd(scope)
    project_fd = None
    parents = []
    try:
        state_raw = stable_read_at(scope_fd, relative_to_scope(scope, state_name), 16 * 1024 * 1024)
        state = json.loads(state_raw.decode("utf-8", "strict"))
        # 先根据请求中的端口和实际 curl 配置鉴权摘要唯一选中实例，绝不遍历
        # shared state 中的其它部署目录。
        candidates = state.get("rag_instances", {})
        parsed = urllib.parse.urlsplit(url)
        if not isinstance(candidates, dict) or not parsed.port:
            fail()
        possible = [project for project, value in candidates.items()
                    if isinstance(value, dict) and value.get("port") == parsed.port
                    and is_within(scope, project)]
        bound = [project for project in possible if is_within(project, config)]
        if len(bound) > 1:
            fail()
        if bound:
            candidate_fd = open_child_directories(scope_fd, relative_to_scope(scope, bound[0]))
            if candidate_fd is None:
                fail()
            try:
                supplied_digest = parse_project_config(candidate_fd, bound[0], config)
            finally:
                os.close(candidate_fd)
            possible = bound
        else:
            supplied_digest = parse_doctor_config(config)
        matches = [project for project in possible
                   if value_digest(candidates[project]) == supplied_digest]
        if len(matches) != 1:
            fail()
        project = os.path.abspath(matches[0])
        digest = value_digest(candidates[project])
        project_fd = open_child_directories(scope_fd, relative_to_scope(scope, project))
        if project_fd is None or verify_instance(state, url, digest, scope, project) != project:
            fail()
        instance = state["rag_instances"][project]
        documents = instance.setdefault("documents", [])
        if not isinstance(documents, list) or len(documents) != len(set(documents)):
            fail()
        for location in documents:
            safe_location(location)
        work = []
        if action == "upload":
            if len(sys.argv) != 8:
                fail()
            source, name = sys.argv[6], sys.argv[7]
            if name in ("", ".", "..") or len(name.encode("utf-8")) > 255 \
                    or any(character in name for character in ("/", "\\", ";", ",")) \
                    or any(ord(character) < 32 or ord(character) == 127 for character in name):
                fail()
            source_raw = stable_read_at(project_fd, relative_to_scope(project, source), 50 * 1024 * 1024)
            location = safe_location("custom-documents/" + name + ".json").as_posix()
            parsed_raw = (json.dumps({"pageContent": source_raw.decode("utf-8", "replace"), "title": name},
                                     ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
            cache_raw = (json.dumps({"synthetic_embedding_cache": True, "location": location},
                                    sort_keys=True, separators=(",", ":")) + "\n").encode()
            document_parent = open_child_directories(project_fd,
                ("data", "anythingllm", "documents", "custom-documents"), create=True)
            cache_parent = open_child_directories(project_fd,
                ("data", "anythingllm", "vector-cache"), create=True)
            parents.extend((document_parent, cache_parent))
            work.extend((target(document_parent, name + ".json", parsed_raw),
                         target(cache_parent, str(uuid.uuid5(uuid.NAMESPACE_URL, location)) + ".json", cache_raw)))
            for item in work:
                publish(item)
        elif action == "remove":
            if len(sys.argv) != 7:
                fail()
            locations = json.loads(sys.argv[6])
            if not isinstance(locations, list):
                fail()
            document_parent = open_child_directories(project_fd,
                ("data", "anythingllm", "documents", "custom-documents"), create=False)
            cache_parent = open_child_directories(project_fd,
                ("data", "anythingllm", "vector-cache"), create=False)
            if document_parent is not None:
                parents.append(document_parent)
            if cache_parent is not None:
                parents.append(cache_parent)
            for location in locations:
                parsed_location = safe_location(location)
                if document_parent is not None:
                    work.append(target(document_parent, parsed_location.parts[1]))
                if cache_parent is not None:
                    work.append(target(cache_parent,
                        str(uuid.uuid5(uuid.NAMESPACE_URL, parsed_location.as_posix())) + ".json"))
            # 全部成员完成类型/硬链接预检后才开始删除。
            for item in work:
                try:
                    os.unlink(item["leaf"], dir_fd=item["parent"])
                except FileNotFoundError:
                    pass
            for parent in set(item["parent"] for item in work):
                os.fsync(parent)
            removed = instance.setdefault("removed_documents", [])
            if not isinstance(removed, list) or len(removed) != len(set(removed)):
                fail()
            for location in removed:
                safe_location(location)
            instance["removed_documents"] = sorted(set(removed) | set(locations))
            publish_state(scope_fd, relative_to_scope(scope, state_name), state)
        elif action == "update":
            if len(sys.argv) != 8:
                fail()
            additions, deletions = json.loads(sys.argv[6]), json.loads(sys.argv[7])
            if not isinstance(additions, list) or not isinstance(deletions, list) \
                    or len(additions) != len(set(additions)) or len(deletions) != len(set(deletions)):
                fail()
            for location in additions + deletions:
                safe_location(location)
            instance["documents"] = sorted((set(documents) | set(additions)) - set(deletions))
            publish_state(scope_fd, relative_to_scope(scope, state_name), state)
        else:
            if len(sys.argv) != 6:
                fail()
            print(json.dumps(documents, separators=(",", ":")))
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
        fail()
    finally:
        for descriptor in parents:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        if project_fd is not None:
            os.close(project_fd)
        os.close(scope_fd)


def value_digest(value):
    digest = value.get("api_key_sha256") if isinstance(value, dict) else None
    if not isinstance(digest, str) or len(digest) != 64:
        fail()
    return digest


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
        fail()
