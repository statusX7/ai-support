#!/usr/bin/env python3
"""从当前启用映射的 AnythingLLM 解析正文构建有界、可核验的词法补召回索引。"""

import argparse
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys

MAX_INDEX_BYTES = 16 * 1024 * 1024
MAX_MAP_BYTES = 16 * 1024 * 1024
MAX_PARSED_BYTES = 256 * 1024 * 1024
MAX_PASSAGE_BYTES = 512 * 1024
ALGORITHM = "crispai-lexical-v1"
QUESTION = re.compile(r"(?im)^[ \t]*(?:#{1,6}[ \t]+)?(?:问(?:题)?|q(?:uestion)?)[ \t]*[:：][ \t]*([^\r\n]+)")
ANSWER = re.compile(r"(?im)^[ \t]*(?:答(?:案)?|a(?:nswer)?)[ \t]*[:：]")


class LexicalError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__("词法补召回索引校验未完成；原索引未替换。")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def strict_json(raw):
    def reject_constant(_value):
        raise ValueError("非标准 JSON 数值")
    return json.loads(raw.decode("utf-8"), parse_constant=reject_constant)


def safe_text(value, maximum, empty=False):
    try:
        return isinstance(value, str) and "\0" not in value and (empty or bool(value.strip())) and len(value.encode("utf-8")) <= maximum
    except UnicodeError:
        return False


def location_parts(value):
    if not safe_text(value, 2048) or "\\" in value or re.search(r"[\x00-\x1f\x7f]", value):
        raise LexicalError("map_invalid")
    parts = value.split("/")
    if len(parts) < 2 or any(part in ("", ".", "..") for part in parts) or not value.endswith(".json"):
        raise LexicalError("map_invalid")
    return parts


def enabled_documents(raw):
    try:
        value = strict_json(raw)
        if not isinstance(value, dict) or value.get("schema_version") != 2 or not isinstance(value.get("documents"), list):
            raise ValueError
        documents, seen = [], set()
        for item in value["documents"]:
            if not isinstance(item, dict) or not re.fullmatch(r"kb_(?:[a-f0-9]{16}|default)", item.get("library_id", "")) \
                    or not re.fullmatch(r"doc_[a-f0-9]{16}", item.get("document_id", "")):
                raise ValueError
            projection = item.get("projection")
            if not safe_text(projection, 255) or re.search(r"[\\/;,\x00-\x1f\x7f]", projection):
                raise ValueError
            location_parts(item.get("location"))
            if "enabled" in item and not isinstance(item["enabled"], bool):
                raise ValueError
            if item.get("enabled") is False:
                continue
            if item["location"] in seen:
                raise ValueError
            seen.add(item["location"])
            documents.append({key: item[key] for key in ("library_id", "document_id", "projection", "location")})
        return documents
    except (ValueError, TypeError, UnicodeError, RecursionError, LexicalError):
        raise LexicalError("map_invalid") from None


def directory_fd(path):
    """逐段 openat，不跟随部署目录或输入子目录中的链接。"""
    value = os.path.abspath(path)
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in Path(value).parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def relative_fd(root_fd, relative):
    parts = relative.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError
    descriptor = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
    finally:
        os.close(descriptor)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_relative(root_fd, relative, maximum, code):
    try:
        descriptor = relative_fd(root_fd, relative)
        with os.fdopen(descriptor, "rb") as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum:
                raise ValueError
            data = source.read(maximum + 1)
            if len(data) > maximum or identity(os.fstat(source.fileno())) != identity(before):
                raise ValueError
            return data, identity(before)
    except (OSError, ValueError):
        raise LexicalError(code) from None


def windows(text, start, end):
    while start < end:
        stop = min(start + 4096, end)
        if stop < end:
            boundary = text.rfind("\n", start + 1024, stop)
            if boundary >= 0:
                stop = boundary + 1
        yield start, stop, ""
        start = stop


def passage_spans(text):
    questions = list(QUESTION.finditer(text))
    cursor = 0
    for position, question in enumerate(questions):
        end = questions[position + 1].start() if position + 1 < len(questions) else len(text)
        if cursor < question.start():
            yield from windows(text, cursor, question.start())
        if ANSWER.search(text, question.end(), end):
            yield question.start(), end, question.group(1).strip()
        else:
            yield from windows(text, question.start(), end)
        cursor = end
    if cursor < len(text):
        yield from windows(text, cursor, len(text))


def spread(indices):
    """先首、中、尾，随后逐层覆盖空隙；结果与机器或时间无关。"""
    if not indices:
        return []
    positions = [0, len(indices) // 2, len(indices) - 1]
    seen, result = set(), []
    intervals = deque([(0, len(indices) - 1)])
    for point in positions:
        if point not in seen:
            seen.add(point)
            result.append(indices[point])
    while intervals:
        start, end = intervals.popleft()
        if start > end:
            continue
        middle = (start + end) // 2
        if middle not in seen:
            seen.add(middle)
            result.append(indices[middle])
        if start < middle:
            intervals.append((start, middle - 1))
        if middle < end:
            intervals.append((middle + 1, end))
    return result


def passage_id(value):
    return "lexical-" + digest(canonical({key: value[key] for key in (
        "library_id", "document_id", "location", "start_byte", "end_byte", "text_sha256")}))


def atomic_publish(directory, name, raw):
    temporary = ".knowledge-lexical-" + secrets.token_hex(12) + ".tmp"
    descriptor = None
    try:
        try:
            current = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
                raise LexicalError("output_invalid")
            old, _ = read_relative(directory, name, MAX_INDEX_BYTES, "output_invalid")
            if old == raw and stat.S_IMODE(current.st_mode) == 0o640 \
                    and (os.geteuid() != 0 or (current.st_uid == 0 and current.st_gid == 1000)):
                return
        except FileNotFoundError:
            pass
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640, dir_fd=directory)
        os.fchmod(descriptor, 0o640)
        if os.geteuid() == 0:
            os.fchown(descriptor, 0, 1000)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = None
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


def build_index(deploy_dir, output=None):
    root = os.path.abspath(deploy_dir)
    destination = os.path.abspath(output or os.path.join(root, "data/runtime/knowledge-lexical.json"))
    if os.path.dirname(destination) != os.path.join(root, "data/runtime") or not re.fullmatch(r"knowledge-lexical\.json(?:\.[A-Za-z0-9_.-]+)?", os.path.basename(destination)):
        raise LexicalError("output_invalid")
    try:
        base = directory_fd(root)
    except OSError:
        raise LexicalError("map_invalid") from None
    try:
        map_raw, _ = read_relative(base, "data/runtime/knowledge-map.json", MAX_MAP_BYTES, "map_invalid")
        documents = enabled_documents(map_raw)
        passages, snapshots, reasons = [], [], set()
        used, source_bytes, indexed_bytes, indexed_documents = 2048, 0, 0, 0
        for document_number, document in enumerate(documents):
            relative = "data/anythingllm/documents/" + document["location"]
            raw, snapshot = read_relative(base, relative, MAX_PARSED_BYTES, "source_invalid")
            snapshots.append((relative, snapshot))
            try:
                parsed = strict_json(raw)
                text = parsed.get("pageContent") if isinstance(parsed, dict) else None
                if not safe_text(text, MAX_PARSED_BYTES, empty=True):
                    raise ValueError
            except (ValueError, UnicodeError, RecursionError):
                raise LexicalError("source_invalid") from None
            source_bytes += len(text.encode("utf-8"))
            parsed_hash, content_hash = digest(raw), digest(text.encode("utf-8"))
            spans, byte_offset = [], 0
            for start, end, question in passage_spans(text):
                size = len(text[start:end].encode("utf-8"))
                spans.append((start, end, question, byte_offset, byte_offset + size))
                byte_offset += size
            priority = spread([i for i, span in enumerate(spans) if span[2]]) + spread([i for i, span in enumerate(spans) if not span[2]])
            allowance = (MAX_INDEX_BYTES - used) // max(1, len(documents) - document_number)
            local_used, selected = 0, []
            for position in priority:
                start, end, question, begin_byte, end_byte = spans[position]
                if end_byte - begin_byte > MAX_PASSAGE_BYTES:
                    reasons.add("passage_too_large")
                    continue
                body = text[start:end]
                entry = {**document, "parsed_sha256": parsed_hash, "content_sha256": content_hash,
                         "start_byte": begin_byte, "end_byte": end_byte, "text": body,
                         "question": question, "text_sha256": digest(body.encode("utf-8"))}
                entry["id"] = passage_id(entry)
                size = len(canonical(entry)) + 1
                if local_used + size > allowance:
                    reasons.add("index_capacity")
                    continue
                local_used += size
                indexed_bytes += end_byte - begin_byte
                selected.append(entry)
            if selected:
                indexed_documents += 1
            passages.extend(sorted(selected, key=lambda entry: entry["start_byte"]))
            used += local_used
        # 发布前复核原映射与源文件身份，不能将一次构建中的新旧资料混成有效索引。
        current_map, _ = read_relative(base, "data/runtime/knowledge-map.json", MAX_MAP_BYTES, "map_invalid")
        if current_map != map_raw:
            raise LexicalError("map_changed")
        for relative, snapshot in snapshots:
            try:
                descriptor = relative_fd(base, relative)
                try:
                    if identity(os.fstat(descriptor)) != snapshot:
                        raise LexicalError("source_changed")
                finally:
                    os.close(descriptor)
            except OSError:
                raise LexicalError("source_changed") from None
        result = {"schema_version": 1, "algorithm": ALGORITHM, "map_sha256": digest(map_raw),
                  "complete": source_bytes == indexed_bytes,
                  "coverage": {"source_documents": len(documents), "indexed_documents": indexed_documents,
                               "omitted_documents": len(documents) - indexed_documents, "source_bytes": source_bytes,
                               "indexed_bytes": indexed_bytes, "omitted_bytes": source_bytes - indexed_bytes,
                               "reasons": sorted(reasons)}, "passages": passages}
        result["payload_sha256"] = digest(canonical(result))
        encoded = canonical(result) + b"\n"
        if len(encoded) > MAX_INDEX_BYTES:
            raise LexicalError("output_invalid")
        target = directory_fd(os.path.dirname(destination))
        try:
            atomic_publish(target, os.path.basename(destination), encoded)
        finally:
            os.close(target)
        return result
    finally:
        os.close(base)


def verify_index(deploy_dir):
    """纯只读；部分覆盖仍有效，但旧映射、坏片段或已索引源变更不能通过。"""
    try:
        base = directory_fd(deploy_dir)
    except OSError:
        raise LexicalError("map_invalid") from None
    try:
        map_raw, _ = read_relative(base, "data/runtime/knowledge-map.json", MAX_MAP_BYTES, "map_invalid")
        documents = enabled_documents(map_raw)
        sources = {item["location"]: item for item in documents}
        index_raw, _ = read_relative(base, "data/runtime/knowledge-lexical.json", MAX_INDEX_BYTES, "index_invalid")
        descriptor = relative_fd(base, "data/runtime/knowledge-lexical.json")
        try:
            info = os.fstat(descriptor)
            if stat.S_IMODE(info.st_mode) != 0o640 or os.geteuid() == 0 and (info.st_uid != 0 or info.st_gid != 1000):
                raise LexicalError("index_invalid")
        finally:
            os.close(descriptor)
        groups, positions, seen = {}, {}, set()
        indexed_bytes = 0
        try:
            index = strict_json(index_raw)
            if not isinstance(index, dict) or index.get("schema_version") != 1 or index.get("algorithm") != ALGORITHM \
                    or not isinstance(index.get("passages"), list) or not isinstance(index.get("complete"), bool):
                raise ValueError
            expected = index.get("payload_sha256")
            payload = {key: value for key, value in index.items() if key != "payload_sha256"}
            if expected != digest(canonical(payload)):
                raise ValueError
            if index.get("map_sha256") != digest(map_raw):
                raise LexicalError("map_changed")
            coverage = index["coverage"]
            fields = ("source_documents", "indexed_documents", "omitted_documents", "source_bytes", "indexed_bytes", "omitted_bytes")
            if not isinstance(coverage, dict) or any(type(coverage.get(key)) is not int or coverage[key] < 0 for key in fields) \
                    or coverage["source_documents"] != len(documents) \
                    or coverage["indexed_documents"] + coverage["omitted_documents"] != len(documents) \
                    or coverage["indexed_bytes"] + coverage["omitted_bytes"] != coverage["source_bytes"] \
                    or index["complete"] != (coverage["omitted_bytes"] == 0) \
                    or not isinstance(coverage.get("reasons"), list) \
                    or any(reason not in ("index_capacity", "passage_too_large") for reason in coverage["reasons"]):
                raise ValueError
            for entry in index["passages"]:
                if not isinstance(entry, dict):
                    raise ValueError
                source = sources.get(entry.get("location"))
                if not source or any(entry.get(key) != source[key] for key in ("library_id", "document_id", "projection", "location")) \
                        or not safe_text(entry.get("text"), MAX_PASSAGE_BYTES, empty=True) \
                        or not safe_text(entry.get("question"), MAX_PASSAGE_BYTES, empty=True) \
                        or any(not isinstance(entry.get(key), str) or not re.fullmatch(r"[a-f0-9]{64}", entry[key])
                               for key in ("parsed_sha256", "content_sha256", "text_sha256")) \
                        or entry["text_sha256"] != digest(entry["text"].encode("utf-8")) \
                        or any(type(entry.get(key)) is not int or entry[key] < 0 for key in ("start_byte", "end_byte")) \
                        or entry["end_byte"] <= entry["start_byte"] \
                        or entry["end_byte"] - entry["start_byte"] != len(entry["text"].encode("utf-8")) \
                        or entry["start_byte"] < positions.get(entry["location"], 0) \
                        or entry.get("id") != passage_id(entry) or entry["id"] in seen \
                        or entry["question"] not in entry["text"]:
                    raise ValueError
                seen.add(entry["id"])
                positions[entry["location"]] = entry["end_byte"]
                groups.setdefault(entry["location"], []).append(entry)
                indexed_bytes += entry["end_byte"] - entry["start_byte"]
            if indexed_bytes != coverage["indexed_bytes"] or len(groups) != coverage["indexed_documents"]:
                raise ValueError
        except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
            raise LexicalError("index_invalid") from None
        actual_bytes = 0
        for document in documents:
            raw, _ = read_relative(base, "data/anythingllm/documents/" + document["location"], MAX_PARSED_BYTES, "source_invalid")
            try:
                parsed = strict_json(raw)
                content = parsed.get("pageContent") if isinstance(parsed, dict) else None
                if not safe_text(content, MAX_PARSED_BYTES, empty=True):
                    raise ValueError
                content = content.encode("utf-8")
            except (ValueError, UnicodeError, RecursionError):
                raise LexicalError("source_invalid") from None
            actual_bytes += len(content)
            parsed_hash, content_hash = digest(raw), digest(content)
            for entry in groups.get(document["location"], []):
                if entry["parsed_sha256"] != parsed_hash or entry["content_sha256"] != content_hash \
                        or content[entry["start_byte"]:entry["end_byte"]] != entry["text"].encode("utf-8"):
                    raise LexicalError("source_changed")
        if actual_bytes != coverage["source_bytes"]:
            raise LexicalError("source_changed")
        current_map, _ = read_relative(base, "data/runtime/knowledge-map.json", MAX_MAP_BYTES, "map_invalid")
        if current_map != map_raw:
            raise LexicalError("map_changed")
        return index
    finally:
        os.close(base)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="原子构建当前启用资料的词法索引")
    build.add_argument("--deploy-dir", required=True)
    build.add_argument("--output", help="同一 data/runtime 目录下的受管候选文件")
    verify = commands.add_parser("verify", help="只读校验当前索引、映射与解析来源")
    verify.add_argument("--deploy-dir", required=True)
    args = parser.parse_args()
    try:
        result = verify_index(args.deploy_dir) if args.command == "verify" else build_index(args.deploy_dir, args.output)
        print(json.dumps({"ok": True, "complete": result["complete"], "coverage": result["coverage"],
                          "schema_version": 1, "map_sha256": result["map_sha256"],
                          "payload_sha256": result["payload_sha256"], "read_only": args.command == "verify"}, ensure_ascii=False))
        return 0
    except (LexicalError, OSError, ValueError, MemoryError, RecursionError) as error:
        print(json.dumps({"ok": False, "error": {"code": getattr(error, "code", "build_failed"),
              "message": "词法补召回索引校验未完成；原索引未替换。"}}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
