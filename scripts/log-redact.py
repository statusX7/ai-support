#!/usr/bin/env python3
"""CrispAI operational-log redactor.

The filter deliberately favors privacy over preserving every diagnostic byte. It
never evaluates the managed .env file and writes only redacted input to stdout.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
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
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size > 1024 * 1024:
            return values
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return values
    for raw in text.splitlines():
        if not raw or raw.lstrip().startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            continue
        try:
            if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
                value = json.loads(value.replace("$$", "$"))
            elif len(value) >= 2 and value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(value, str):
            values[key] = value
    return values


def collect_secrets(values: dict[str, str]) -> list[str]:
    secrets: set[str] = set()
    for key, value in values.items():
        if value and key not in NON_SECRET_ENV and (SENSITIVE_ENV.search(key) or key == "CRISP_WEBSITE_ID"):
            secrets.add(value)
        if key == "AI_CUSTOM_HEADERS_JSON" and value:
            try:
                headers = json.loads(value)
            except json.JSONDecodeError:
                headers = None
            if isinstance(headers, dict):
                for header_value in headers.values():
                    if isinstance(header_value, str) and header_value:
                        secrets.add(header_value)
    expanded: set[str] = set()
    for secret in secrets:
        if len(secret) < 3:
            continue
        expanded.add(secret)
        # 常见日志可能保存 JSON 转义、URL 编码或 Base64 形式。所有变体只在
        # 内存中构造，不写入诊断文件。
        expanded.add(json.dumps(secret, ensure_ascii=False)[1:-1])
        expanded.add(urllib.parse.quote(secret, safe=""))
        expanded.add(urllib.parse.quote_plus(secret, safe=""))
        raw = secret.encode("utf-8")
        expanded.add(base64.b64encode(raw).decode("ascii"))
        expanded.add(base64.urlsafe_b64encode(raw).decode("ascii"))
        expanded.add(base64.urlsafe_b64encode(raw).decode("ascii").rstrip("="))
        for part in secret.splitlines():
            if len(part) >= 3:
                expanded.add(part)
    return sorted((item for item in expanded if len(item) >= 3), key=len, reverse=True)


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
    secrets = collect_secrets(parse_env(Path(args.env)))
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
    raise SystemExit(status)
