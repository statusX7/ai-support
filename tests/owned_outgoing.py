#!/usr/bin/env python3
"""隔离外部验收只按本机登记的出站身份计数，不依赖可见昵称或自动徽标。"""
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path


def read_json(path, fallback, maximum):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return fallback
    with os.fdopen(descriptor, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > maximum:
            raise ValueError("身份记录不安全")
        raw = handle.read(maximum + 1)
        if len(raw) > maximum:
            raise ValueError("身份记录超限")
        return json.loads(raw.decode("utf-8", "strict"))


def fingerprint(value):
    text = str(value)
    if not re.fullmatch(r"(?:0|[1-9][0-9]{0,15})", text) or int(text) > 9007199254740991:
        return None
    return text


def annotate(root, website, session, payload):
    directory = Path(root) / "data/runtime"
    if directory.is_symlink() or directory.parent.is_symlink():
        raise ValueError("身份目录不安全")
    key = hashlib.sha256((website + "\0" + session).encode()).hexdigest()
    state = read_json(directory / ("session-" + key + ".json"), {}, 2097152)
    records = state.get("outgoing", {})
    if not isinstance(records, dict) or state and (state.get("website_id") != website or state.get("session_id") != session):
        raise ValueError("身份记录会话不匹配")
    messages = payload.get("data")
    if not isinstance(messages, list) or len(messages) > 10000:
        raise ValueError("消息响应无效")
    buckets = {}
    for message in messages:
        if not isinstance(message, dict):
            raise ValueError("消息响应无效")
        value = fingerprint(message.get("fingerprint"))
        owned = False
        if value is not None and message.get("from") == "operator":
            owned = value in records
            if not owned:
                suffix = format(int(value) % 256, "02x")
                if suffix not in buckets:
                    bucket = read_json(directory / ("owned-" + key + "-" + suffix + ".json"), {"schema_version": 1, "fingerprints": []}, 1048576)
                    values = bucket.get("fingerprints")
                    if bucket.get("schema_version") != 1 or not isinstance(values, list) or len(values) > 50000 or any(not isinstance(item, str) or fingerprint(item) is None for item in values):
                        raise ValueError("身份索引无效")
                    buckets[suffix] = set(values)
                owned = value in buckets[suffix]
        message["__crispai_owned"] = owned
    return payload


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("参数不完整")
        data = sys.stdin.buffer.read(2097153)
        if len(data) > 2097152:
            raise ValueError("消息响应超限")
        result = annotate(*sys.argv[1:], json.loads(data.decode("utf-8", "strict")))
        json.dump(result, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        sys.stderr.write("隔离验收失败：无法可靠核对本项目出站身份，未输出消息。\n")
        sys.exit(1)
