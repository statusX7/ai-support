#!/usr/bin/env python3
"""CrispAI operational-log redactor.

The filter deliberately favors privacy over preserving every diagnostic byte. It
never evaluates the managed .env file and writes only redacted input to stdout.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import stat
import sys
import urllib.parse
from pathlib import Path


SENSITIVE_ENV = re.compile(
    r"(?:KEY|TOKEN|SECRET|PASSWORD|AUTH|COOKIE|CREDENTIAL|SIGNATURE)", re.I
)
NON_SECRET_ENV = {"CRISP_TOKEN_TIER", "N8N_SECURE_COOKIE"}
SENSITIVE_KEY = re.compile(
    r"(?:api[_-]?key|token|secret|password|authorization|cookie|credential|signature|"
    r"session[_-]?id|website[_-]?id|fingerprint|visitor|email|phone)$",
    re.I,
)
BODY_KEY = re.compile(
    r"(?:body|content|prompt|messages?|input|output|question|answer|knowledge|payload|"
    r"request[_-]?body|response[_-]?body|binary|image[_-]?(?:url|data))$",
    re.I,
)
QUERY_SECRET = re.compile(
    r"(?:key|token|secret|signature|authorization|auth|password|credential|api[_-]?key|"
    r"access[_-]?token|hook[_-]?secret|subscribe|subscription|sig|code|ticket)$",
    re.I,
)
URL_RE = re.compile(r"https?://[^\s<>\"']+", re.I)
AUTH_RE = re.compile(r"(?i)\b(Bearer|Basic)\s+[^\s,;\"']+")
ASSIGN_RE = re.compile(
    r"(?i)(\b(?:api[_ -]?key|token|secret|password|authorization|cookie|credential|"
    r"signature)\b\s*[:=]\s*)([^\s,;]+)"
)
JSON_VALUE_RE = re.compile(
    r'(?i)([\"\'](?:body|content|prompt|messages?|input|output|question|answer|knowledge|'
    r'payload|request[_-]?body|response[_-]?body|session[_-]?id|website[_-]?id|fingerprint)'
    r'[\"\']\s*:\s*)([\"\'])(.*?)(?<!\\)\2'
)
JSON_SECRET_VALUE_RE = re.compile(
    r'(?i)(["\'](?:api[_-]?key|token|secret|password|authorization|cookie|credential|'
    r'signature|session[_-]?id|website[_-]?id|fingerprint)["\']\s*:\s*)'
    r'(["\'])(.*?)(?<!\\)\2'
)
EMAIL_RE = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I)
PHONE_RE = re.compile(r"(?<!\w)(?:\+?\d[\d .()-]{6,}\d)(?!\w)")


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 1024 * 1024:
        raise ValueError("unsafe environment file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 1024 * 1024:
            raise ValueError("unsafe environment file")
        text = stream.read()
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if "=" not in raw:
            raise ValueError("invalid environment line")
        key, value = raw.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
            raise ValueError("invalid environment key")
        if value.startswith('"'):
            value = json.loads(value.replace("$$", "$"))
        elif value.startswith("'"):
            if len(value) < 2 or not value.endswith("'"):
                raise ValueError("invalid quoted value")
            value = value[1:-1]
        if not isinstance(value, str):
            raise ValueError("invalid environment value")
        values[key] = value
    return values


def collect_secrets(values: dict[str, str], extra: set[str] | None = None) -> list[str]:
    secrets: set[str] = set(extra or ())
    for key, value in values.items():
        if value and key not in NON_SECRET_ENV and (SENSITIVE_ENV.search(key) or key == "CRISP_WEBSITE_ID"):
            secrets.add(value)
        if key == "AI_CUSTOM_HEADERS_JSON" and value:
            headers = json.loads(value)
            if not isinstance(headers, dict) or any(not isinstance(item, str) for item in headers.values()):
                raise ValueError("invalid environment headers")
            secrets.update(headers.values())
    if values.get("CRISP_TOKEN_IDENTIFIER") and values.get("CRISP_TOKEN_KEY"):
        secrets.add(values["CRISP_TOKEN_IDENTIFIER"] + ":" + values["CRISP_TOKEN_KEY"])
    expanded: set[str] = set()
    for secret in secrets:
        if len(secret) < 3:
            continue
        expanded.add(secret)
        # 常见日志可能保存 JSON 转义、URL 编码或 Base64 形式。所有变体只在
        # 内存中构造，不写入诊断文件。
        expanded.add(json.dumps(secret, ensure_ascii=False)[1:-1])
        expanded.add(json.dumps(secret, ensure_ascii=True)[1:-1])
        encoded = urllib.parse.quote(secret, safe="")
        lowercase = lambda text: re.sub(r"%[0-9A-Fa-f]{2}", lambda match: match.group(0).lower(), text)
        plus_encoded = urllib.parse.quote_plus(secret, safe="")
        for value in (encoded, lowercase(encoded), plus_encoded, lowercase(plus_encoded)):
            expanded.add(value)
            expanded.add(lowercase(value))
            # 双重编码中第二层与第一层的十六进制大小写可分别变化。
            doubled = urllib.parse.quote(value, safe="")
            expanded.add(doubled)
            expanded.add(lowercase(doubled))
        raw = secret.encode("utf-8")
        expanded.add(base64.b64encode(raw).decode("ascii"))
        expanded.add(base64.urlsafe_b64encode(raw).decode("ascii"))
        expanded.add(base64.urlsafe_b64encode(raw).decode("ascii").rstrip("="))
        for part in secret.splitlines():
            if len(part) >= 3:
                expanded.add(part)
    return sorted((item for item in expanded if len(item) >= 3), key=len, reverse=True)


def provider_secret_files(env: Path) -> list[Path]:
    directory = env.parent
    for part in ("secrets", "provider", "generations"):
        directory /= part
        if directory.is_symlink():
            raise ValueError("unsafe secret directory")
        if not directory.exists():
            return []
        if not directory.is_dir():
            raise ValueError("invalid secret directory")
    files: list[Path] = []
    total = 0
    for file in directory.iterdir():
        # 所有生效、历史和导入草稿代次均纳入，不只处理当前主接口。
        if not re.fullmatch(r"(?:draft-)?[a-f0-9]{32}\.json", file.name):
            continue
        info = file.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 16 * 1024 * 1024:
            raise ValueError("unsafe secret file")
        files.append(file)
        total += info.st_size
        if len(files) > 4096 or total > 64 * 1024 * 1024:
            raise ValueError("secret scan limit")
    return files


def instance_fingerprint(env: Path) -> tuple:
    files = provider_secret_files(env)
    return tuple((str(file), file.stat().st_ino, file.stat().st_mtime_ns, file.stat().st_ctime_ns, file.stat().st_size) for file in [env, *sorted(files)] if file.exists())


def collect_instance_secrets(env: Path) -> list[str]:
    extra: set[str] = set()
    for file in provider_secret_files(env):
        fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, encoding="utf-8") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 16 * 1024 * 1024:
                raise ValueError("unsafe secret file")
            value = json.load(stream)
        entries = value.get("entries") if isinstance(value, dict) else None
        if not isinstance(entries, dict) or len(entries) > 21:
            raise ValueError("invalid secret document")
        for entry in entries.values():
            if not isinstance(entry, dict) or not isinstance(entry.get("api_key"), str):
                raise ValueError("invalid secret entry")
            extra.add(entry["api_key"])
            headers = entry.get("custom_headers", {})
            if not isinstance(headers, dict) or any(not isinstance(item, str) for item in headers.values()):
                raise ValueError("invalid secret headers")
            extra.update(headers.values())
    return collect_secrets(parse_env(env), extra)


def redact_object(value: object) -> object:
    if isinstance(value, dict):
        result: dict[str, object] = {}
        for key, child in value.items():
            label = str(key)
            if SENSITIVE_KEY.search(label):
                result[label] = "[已脱敏]"
            elif BODY_KEY.search(label):
                result[label] = "[正文已省略]"
            else:
                result[label] = redact_object(child)
        return result
    if isinstance(value, list):
        return [redact_object(child) for child in value[:100]]
    return value


def redact_url(match: re.Match[str], mode: str) -> str:
    raw = match.group(0)
    trailing = ""
    while raw and raw[-1] in ").,;]}":
        trailing = raw[-1] + trailing
        raw = raw[:-1]
    try:
        parsed = urllib.parse.urlsplit(raw)
        if mode == "export":
            return "[链接已脱敏]" + trailing
        hostname = parsed.hostname or ""
        if ":" in hostname and not hostname.startswith("["):
            hostname = f"[{hostname}]"
        try:
            port = f":{parsed.port}" if parsed.port is not None else ""
        except ValueError:
            return "[链接已脱敏]" + trailing
        netloc = hostname + port
        if parsed.username is not None or parsed.password is not None:
            netloc = "[凭据已脱敏]@" + netloc
        path_parts = parsed.path.split("/")
        previous = ""
        safe_path: list[str] = []
        for part in path_parts:
            decoded = urllib.parse.unquote(part)
            looks_secret = bool(
                re.search(r"(?:token|secret|subscribe|signature|auth|credential|hook)$", previous, re.I)
                or (len(decoded) >= 16 and re.fullmatch(r"[A-Za-z0-9._~+=%-]+", decoded))
            )
            safe_path.append("[已脱敏]" if looks_secret else part)
            previous = decoded
        pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        query = urllib.parse.urlencode(
            [(key, "[已脱敏]" if QUERY_SECRET.search(key) else value) for key, value in pairs]
        )
        sanitized = urllib.parse.urlunsplit(
            (parsed.scheme, netloc, "/".join(safe_path), query, "")
        )
        return sanitized + trailing
    except (TypeError, ValueError):
        return "[链接已脱敏]" + trailing


def redact_line(line: str, secrets: list[str], mode: str) -> str:
    for secret in secrets:
        line = line.replace(secret, "[已脱敏]")
    line = AUTH_RE.sub(lambda match: f"{match.group(1)} [已脱敏]", line)
    line = ASSIGN_RE.sub(lambda match: match.group(1) + "[已脱敏]", line)
    line = JSON_SECRET_VALUE_RE.sub(
        lambda match: match.group(1) + match.group(2) + "[已脱敏]" + match.group(2), line
    )
    line = JSON_VALUE_RE.sub(lambda match: match.group(1) + '"[正文已省略]"', line)
    line = URL_RE.sub(lambda match: redact_url(match, mode), line)
    line = EMAIL_RE.sub("[邮箱已脱敏]", line)
    line = PHONE_RE.sub("[号码已脱敏]", line)

    stripped = line.strip()
    if stripped.startswith("{") and stripped.endswith("}") and len(stripped) <= 1024 * 1024:
        try:
            parsed = json.loads(stripped)
        except json.JSONDecodeError:
            pass
        else:
            line = json.dumps(redact_object(parsed), ensure_ascii=False, separators=(",", ":"))
    return line


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--env", required=True)
    parser.add_argument("--mode", choices=("display", "export"), default="display")
    parser.add_argument("--help", action="help")
    args = parser.parse_args()
    env = Path(args.env)
    fingerprint = instance_fingerprint(env)
    secrets = collect_instance_secrets(env)
    stream = sys.stdin.buffer
    max_line = 256 * 1024
    while True:
        raw = stream.readline(max_line + 1)
        if not raw:
            break
        truncated = len(raw) > max_line and not raw.endswith(b"\n")
        if truncated:
            prefix = raw[:max_line]
            chunk = raw
            while chunk and not chunk.endswith(b"\n"):
                chunk = stream.readline(max_line + 1)
            raw = prefix + "[单行已截断]".encode("utf-8")
        text = raw.decode("utf-8", errors="replace").rstrip("\n\r")
        current = instance_fingerprint(env)
        if current != fingerprint:
            # 长期 follow 时也须在输出前纳入新 Key，不能沿用开启查看时的旧清单。
            secrets = collect_instance_secrets(env)
            fingerprint = current
        # follow 模式下 stdin 会长期保持打开；stdout 重定向文件或管道时
        # Python 默认使用块缓冲。每条脱敏记录必须立即可见，不能等待 EOF。
        print(redact_line(text, secrets, args.mode), flush=True)
    return 0


if __name__ == "__main__":
    try:
        status = main()
    except KeyboardInterrupt:
        # follow 的 Ctrl+C 由外层日志入口给出中文结果；
        # 脱敏过滤器不应在管理员终端打印 Python traceback。
        status = 130
    except (OSError, ValueError, TypeError, UnicodeError):
        print("无法完整读取本实例秘密清单，已停止日志输出；请检查受限凭据文件后重试。", file=sys.stderr)
        status = 1
    raise SystemExit(status)
