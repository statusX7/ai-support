#!/usr/bin/env python3
"""受管主备接口池：非敏感配置、不可变秘密代次与原子发布。"""

import argparse
import base64
import copy
from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


POLICY = {"question_timeout_ms": 90000, "call_timeout_ms": 20000, "connect_timeout_ms": 5000,
          "max_attempts": 21, "cooldown_initial_ms": 60000, "cooldown_max_ms": 300000, "pool_cooldown_ms": 3000}
BOUNDS = {"question_timeout_ms": (1000, 180000), "call_timeout_ms": (1000, 60000), "connect_timeout_ms": (100, 10000),
          "max_attempts": (1, 21), "cooldown_initial_ms": (1000, 300000), "cooldown_max_ms": (1000, 3600000), "pool_cooldown_ms": (100, 60000)}
FORBIDDEN = {"authorization", "host", "connection", "content-length", "content-type", "transfer-encoding", "cookie", "proxy-authorization", "x-crispai-question"}
MODEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,511}\Z")
IDENTIFIER = re.compile(r"p_[a-f0-9]{24}\Z")

# 适配器返回的上游正文不可信。管理面只保留这些稳定分类和本项目自有说明，
# 既让交互层能给出准确下一步，也避免 URL、Header 或密钥随异常内容外泄。
ADAPTER_FAILURES = {
    "authentication_failed": ("authentication_failed", 3, "接口鉴权失败；请核对本接口的地址、Key 与调用权限，原配置未更改"),
    "model_unavailable": ("model_unavailable", 1, "所选模型或对应推理端点不可用；请核对模型原名、请求协议与接口地址，原配置未更改"),
    "model_not_found": ("model_unavailable", 1, "所选模型或对应推理端点不可用；请核对模型原名、请求协议与接口地址，原配置未更改"),
    "protocol_error": ("protocol_error", 1, "接口响应不符合所选 Chat Completions 或 Responses 协议；请核对协议与地址路径，原配置未更改"),
    "protocol_mismatch": ("protocol_error", 1, "接口响应不符合所选 Chat Completions 或 Responses 协议；请核对协议与地址路径，原配置未更改"),
    "unsupported_protocol": ("protocol_error", 1, "接口响应不符合所选 Chat Completions 或 Responses 协议；请核对协议与地址路径，原配置未更改"),
    "provider_adapter_error": ("protocol_error", 1, "接口适配或响应处理未通过；请核对所选协议、地址路径与响应格式，原配置未更改"),
    "invalid_response": ("invalid_response", 1, "接口返回空正文、非 JSON 或结构不符合所选协议；原配置未更改"),
    "rate_limited": ("rate_limited", 4, "接口触发请求频率限制；已按服务端要求进入冷却，可核对备用接口状态"),
    "quota_exhausted": ("quota_exhausted", 4, "接口额度或余额不足；不会立即重复请求同一授权范围，可补充额度或使用独立授权的备用接口"),
    "upstream_timeout": ("upstream_timeout", 4, "接口推理在限定时间内没有完成；请核对网络、模型响应时间与单次请求期限"),
    "upstream_unavailable": ("upstream_unavailable", 4, "接口返回服务端故障；请核对服务状态与备用接口"),
    "connection_failed": ("connection_failed", 4, "应用环境无法建立接口连接；请核对 DNS、TLS、接口地址与容器网络"),
    "temporarily_unavailable": ("temporarily_unavailable", 4, "本地 Provider 适配器当前不可用；原配置未更改，请运行状态与自检"),
    "models_unavailable": ("models_unavailable", 2, "接口未提供可用模型列表；可以手动填写模型原名后执行真实推理验证"),
    "safety_refusal": ("safety_refusal", 1, "模型拒绝了合成验证内容；原配置未更改"),
    "vision_unsupported": ("vision_unsupported", 1, "所选模型未通过图片能力验证；原配置未更改"),
}


class PoolError(Exception):
    def __init__(self, code, message, status=1):
        super().__init__(message)
        self.code, self.status = code, status


def require(condition, code, message):
    if not condition:
        raise PoolError(code, message)


def process_identity(pid):
    boot = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    require(bool(re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", boot)),
            "invalid_configuration", "无法核对窗口操作的系统启动标识")
    try:
        process = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except (FileNotFoundError, ProcessLookupError):
        return None
    # comm可包含空格及右括号；最后一个右括号后才是从字段3开始的固定字段。
    fields = process.rsplit(")", 1)[-1].split()
    require(")" in process and len(fields) > 19 and fields[19].isdigit(),
            "invalid_configuration", "无法核对窗口操作的进程启动标识")
    return boot, int(fields[19])


def transaction_owner():
    pid = os.getpid()
    identity = process_identity(pid)
    require(identity is not None, "invalid_configuration", "无法记录窗口操作的进程身份")
    return {"owner_pid": pid, "owner_boot_id": identity[0], "owner_start_ticks": identity[1]}


def inherited_maintenance_descriptor(lock_path):
    descriptor = os.environ.get("MAINTENANCE_LOCK_FD", "")
    if (os.environ.get("CRISP_AI_MAINTENANCE_LOCK_HELD") != "1"
            or os.environ.get("CRISP_AI_MAINTENANCE_LOCK_PATH") != str(lock_path)
            or not re.fullmatch(r"[0-9]{1,9}", descriptor) or int(descriptor) < 3):
        return None
    descriptor = int(descriptor)
    try:
        opened, current = os.fstat(descriptor), lock_path.lstat()
        if (stat.S_ISREG(opened.st_mode) and stat.S_ISREG(current.st_mode)
                and (opened.st_dev, opened.st_ino) == (current.st_dev, current.st_ino)
                and os.readlink(f"/proc/self/fd/{descriptor}") == str(lock_path)):
            return descriptor
    except OSError:
        pass
    return None


@contextmanager
def maintenance_lock(root):
    temporary = root / "tmp"
    temporary.mkdir(mode=0o700, exist_ok=True)
    require(temporary.is_dir() and not temporary.is_symlink(), "unsafe_file", "维护锁目录不安全")
    lock_path = temporary / "maintenance.lock"
    descriptor = inherited_maintenance_descriptor(lock_path)
    inherited = descriptor is not None
    previous = None
    try:
        if not inherited:
            descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        opened, current = os.fstat(descriptor), lock_path.lstat()
        require(stat.S_ISREG(opened.st_mode) and stat.S_ISREG(current.st_mode)
                and (opened.st_dev, opened.st_ino) == (current.st_dev, current.st_ino), "unsafe_file", "维护锁文件不安全")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PoolError("maintenance_busy", "另一个安装、更新、备份或恢复任务正在运行；接口配置未提交") from None
        values = {"CRISP_AI_MAINTENANCE_LOCK_HELD": "1", "MAINTENANCE_LOCK_FD": str(descriptor),
                  "CRISP_AI_MAINTENANCE_LOCK_PATH": str(lock_path)}
        previous = {key: os.environ.get(key) for key in values}
        os.environ.update(values)
        yield descriptor
    finally:
        if previous is not None:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        # 不显式unlock：继承FD属于父维护事务；新FD关闭时按内核引用计数释放。
        if descriptor is not None and not inherited:
            os.close(descriptor)


def regular(file, maximum=1048576):
    info = file.lstat()
    require(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode) and 0 < info.st_size <= maximum,
            "unsafe_file", "配置必须是大小受限的普通文件")


def read(file, maximum=1048576):
    regular(file, maximum)
    raw = file.read_text(encoding="utf-8")
    def pairs(items):
        result = {}
        for key, value in items:
            require(isinstance(key, str) and key not in result, "invalid_config", "配置键必须唯一")
            result[key] = value
        return result
    try:
        result = json.loads(raw, object_pairs_hook=pairs)
    except json.JSONDecodeError:
        import yaml
        class Loader(yaml.SafeLoader):
            pass
        def mapping(loader, node):
            return pairs([(loader.construct_object(key, deep=True), loader.construct_object(value, deep=True)) for key, value in node.value])
        Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
        result = yaml.load(raw, Loader=Loader)
    require(isinstance(result, dict), "invalid_config", "配置必须是对象")
    return result


def directory(file, mode=0o750):
    file.mkdir(parents=True, exist_ok=True, mode=mode)
    require(file.is_dir() and not file.is_symlink(), "unsafe_file", "受管目录不可使用符号链接")
    os.chmod(file, mode)
    if os.geteuid() == 0:
        os.chown(file, 0, 1000)


def atomic(file, value, mode=0o640):
    require(not file.is_symlink(), "unsafe_file", "受管文件不可使用符号链接")
    descriptor, temporary = tempfile.mkstemp(prefix=file.name + ".tmp-", dir=file.parent)
    try:
        os.fchmod(descriptor, mode)
        if os.geteuid() == 0:
            os.fchown(descriptor, 0, 1000 if mode == 0o640 else 0)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, file)
        parent = os.open(file.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_env(file):
    regular(file)
    result = {}
    for line in file.read_text(encoding="utf-8").splitlines():
        if not re.match(r"^[A-Z][A-Z0-9_]*=", line):
            continue
        name, value = line.split("=", 1)
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = json.loads(value.replace("$$", "$"))
        elif len(value) >= 2 and value.startswith("'") and value.endswith("'"):
            value = value[1:-1]
        result.setdefault(name, value)
    return result


def env_text(file, values):
    current = file.read_text(encoding="utf-8") if file.exists() else ""
    remaining, output = dict(values), []
    def encode(value):
        return str(value) if re.fullmatch(r"[A-Za-z0-9._~:/@+,=%?&-]+", str(value)) else json.dumps(str(value), ensure_ascii=False).replace("$", "$$")
    for line in current.splitlines():
        name = line.split("=", 1)[0]
        if name in values:
            if name in remaining:
                output.append(name + "=" + encode(remaining.pop(name)))
        else:
            output.append(line)
    output.extend(name + "=" + encode(value) for name, value in remaining.items())
    return "\n".join(output) + "\n"


def headers(value):
    require(isinstance(value, dict) and len(value) <= 32, "invalid_headers", "自定义请求头最多32项")
    result = {}
    for name, content in value.items():
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{0,99}", name) and name.lower() not in FORBIDDEN
                and not name.lower().startswith("proxy-") and name.lower() not in result, "invalid_headers", "请求头名称无效或重复")
        require(isinstance(content, str) and len(content) <= 4096 and not re.search(r"[\x00-\x1f\x7f]", content), "invalid_headers", "请求头值无效")
        result[name.lower()] = content
    return result


def policy(value):
    require(isinstance(value, dict) and not (set(value) - set(POLICY)), "invalid_policy", "策略字段无效")
    result = dict(POLICY, **value)
    for name, (low, high) in BOUNDS.items():
        require(type(result[name]) is int and low <= result[name] <= high, "invalid_policy", "策略数值超出允许范围")
    require(result["connect_timeout_ms"] <= result["call_timeout_ms"] <= result["question_timeout_ms"]
            and result["cooldown_initial_ms"] <= result["cooldown_max_ms"], "invalid_policy", "连接、调用、问题时间或冷却先后限制无效")
    return result


def normalize_api_base(value):
    require(isinstance(value, str) and 0 < len(value) <= 4096, "invalid_url", "接口地址无效")
    base = value.rstrip("/")
    require(bool(base) and "?" not in base and "#" not in base and not re.search(r"[\\\x00-\x20\x7f]", base), "invalid_url", "接口地址无效")
    url = urllib.parse.urlsplit(base)
    try:
        port = url.port
        decoded = urllib.parse.unquote(url.path, errors="strict")
    except (UnicodeDecodeError, ValueError):
        raise PoolError("invalid_url", "接口地址无效") from None
    require(url.scheme in ("https", "http") and url.hostname and not url.username and not url.password and not url.query and not url.fragment
            and (port is None or 1 <= port <= 65535)
            and (url.scheme != "http" or url.hostname in ("127.0.0.1", "localhost", "host.docker.internal", "::1")),
            "invalid_url", "接口地址必须为安全地址；明文仅限受管本机网关")
    require("\\" not in decoded and not any(segment in (".", "..") for segment in decoded.split("/")),
            "invalid_url", "接口地址不得包含路径穿越")
    path = url.path.rstrip("/")
    if not path.endswith("/v1"):
        path += "/v1"
    base = urllib.parse.urlunsplit((url.scheme, url.netloc, path, "", ""))
    require(len(base) <= 4096, "invalid_url", "接口地址过长")
    return base


def entry(value, secret):
    require(isinstance(value, dict) and IDENTIFIER.fullmatch(value.get("id", "")) and type(value.get("enabled")) is bool,
            "invalid_entry", "接口标识或启用状态无效")
    require(isinstance(value.get("name"), str) and 0 < len(value["name"]) <= 80 and not re.search(r"[\x00-\x1f\x7f]", value["name"]), "invalid_entry", "接口名称无效")
    value["base_url"] = normalize_api_base(value.get("base_url"))
    require(value.get("api_mode") in ("chat_completions", "responses") and MODEL.fullmatch(value.get("model", "")), "invalid_entry", "接口模型或协议无效")
    require(type(value.get("context_window")) is int and 256 <= value["context_window"] <= 2097152
            and type(value.get("max_output_tokens")) is int and 1 <= value["max_output_tokens"] < value["context_window"], "invalid_entry", "接口上下文或输出限制无效")
    require(isinstance(value.get("capabilities"), dict) and all(type(value["capabilities"].get(key)) is bool for key in ("chat_completions", "responses", "vision")), "invalid_entry", "接口能力字段无效")
    require(not value.get("draft") or value.get("enabled") is False, "draft_disabled", "待补凭据的接口不能启用")
    require(isinstance(secret, dict) and isinstance(secret.get("api_key"), str) and (secret["api_key"] or value.get("draft") is True)
            and len(secret["api_key"]) <= 16384 and not re.search(r"[\x00-\x1f\x7f]", secret["api_key"]), "invalid_key", "接口 Key 为空或包含控制字符")
    secret["custom_headers"] = headers(secret.get("custom_headers", {}))
    value["custom_header_names"] = list(secret["custom_headers"])
    return value


def source_schema(value):
    require(isinstance(value, dict) and value.get("schema_version") == 1
            and not (set(value) - {"schema_version", "revision", "primary_id", "entries", "policy"}), "invalid_pool", "非敏感池源结构无效或包含秘密字段")
    require(type(value.get("revision", 0)) is int and value.get("revision", 0) >= 0, "invalid_pool", "接口池代次无效")
    items = value.get("entries")
    require(isinstance(items, list) and 1 <= len(items) <= 21, "pool_capacity", "接口池最多21个接口，停用及草稿接口仍占名额")
    require(all(isinstance(item, dict) for item in items) and len({item.get("id") for item in items}) == len(items), "invalid_entry", "接口标识重复或无效")
    allowed = {"id", "name", "role", "order", "enabled", "base_url", "model", "api_mode", "custom_header_names", "capabilities", "context_window", "max_output_tokens", "draft"}
    for index, item in enumerate(items):
        require(not (set(item) - allowed) and type(item.get("draft", False)) is bool, "invalid_entry", "接口源包含不支持或敏感字段")
        require(item.get("order") == index and item.get("role") == ("primary" if index == 0 else "backup"), "invalid_order", "接口顺序或角色无效")
        names = item.get("custom_header_names", [])
        require(isinstance(names, list) and len(names) == len(set(names)), "invalid_headers", "请求头名称列表无效")
        checked = copy.deepcopy(item)
        entry(checked, {"api_key": "schema-validation-only", "custom_headers": {name: "" for name in names}})
    require(items[0]["id"] == value.get("primary_id") and items[0]["enabled"] is True and not items[0].get("draft"), "primary_required", "必须有且仅有一个启用主接口")
    value["policy"] = policy(value.get("policy", {}))
    return value


def rag_context_window(value):
    windows = [item["context_window"] for item in value["entries"] if item["enabled"] and not item.get("draft")
               and item["capabilities"].get(item["api_mode"]) is True]
    require(bool(windows), "no_capable_provider", "至少需要一个启用且协议有效的文字接口")
    return max(windows)


class Manager:
    def __init__(self, root):
        self.root = Path(root).absolute()
        self.source = self.root / "config/provider-pool.yaml"
        self.applied = self.root / "config/provider-pool-applied.json"
        self.secrets = self.root / "secrets/provider/generations"
        self.env = self.root / ".env"
        self.transaction = self.root / "config/provider-pool-transaction.json"

    def save_draft(self, value, secret):
        generation = secrets.token_hex(16)
        value = copy.deepcopy(value)
        value["draft_secrets_generation"] = generation
        directory(self.secrets)
        atomic(self.secrets / ("draft-" + generation + ".json"), {"schema_version": 1, "generation": generation, "entries": secret})
        atomic(self.root / "config/provider-pool-import-draft.json", value)
        result = self.public(value)
        result.update(applied=False, draft=True, message="导入草稿已保存；补全主接口凭据后可应用，当前可用池保持不变")
        return result

    def load_draft(self):
        value = read(self.root / "config/provider-pool-import-draft.json")
        generation = value.get("draft_secrets_generation", "")
        require(bool(re.fullmatch(r"[a-f0-9]{32}", generation)), "invalid_draft", "导入草稿缺少一致的本机凭据引用")
        secret = read(self.secrets / ("draft-" + generation + ".json"), 16777216)
        require(secret.get("generation") == generation, "invalid_draft", "导入草稿与秘密代次不一致")
        return value, secret["entries"]

    def load(self):
        value = read(self.applied)
        require(value.get("schema_version") == 1 and type(value.get("revision")) is int and value["revision"] > 0
                and re.fullmatch(r"[a-f0-9]{32}", value.get("secrets_generation", "")), "invalid_pool", "接口池有效投影无效")
        secret = read(self.secrets / (value["secrets_generation"] + ".json"), 16777216)
        require(secret.get("revision") == value["revision"] and secret.get("generation") == value["secrets_generation"], "invalid_pool", "接口池与秘密代次不一致")
        self.validate(value, secret["entries"])
        return value, secret["entries"]

    @staticmethod
    def validate(value, secret):
        source_schema({key: copy.deepcopy(content) for key, content in value.items() if key != "secrets_generation"})
        values = value.get("entries")
        require(isinstance(values, list) and 1 <= len(values) <= 21 and len({item["id"] for item in values}) == len(values), "pool_capacity", "接口池最多21个接口，停用接口仍占名额")
        require(values[0]["id"] == value.get("primary_id") and values[0]["enabled"] and values[0]["role"] == "primary"
                and all(item["role"] == "backup" for item in values[1:]), "primary_required", "接口池必须有且仅有一个启用主接口")
        for index, item in enumerate(values):
            require(item.get("order") == index, "invalid_order", "备用顺序无效")
            entry(item, secret.get(item["id"]))
        value["policy"] = policy(value.get("policy", {}))

    @staticmethod
    def public(value):
        result = {key: copy.deepcopy(value[key]) for key in ("revision", "primary_id", "entries", "policy")}
        result["ok"] = True
        for item in result["entries"]:
            item["key_status"] = "待填写" if item.get("draft") else "已保存"
        return result

    @staticmethod
    def verify_adapter_readback(value, observed, configuration_state="applied"):
        expected_entries = [(item["id"], item["enabled"]) for item in value["entries"]]
        actual = observed.get("entries") if isinstance(observed, dict) else None
        actual_entries = [
            (item.get("id"), item.get("enabled"))
            for item in actual
        ] if isinstance(actual, list) and all(isinstance(item, dict) and type(item.get("enabled")) is bool for item in actual) else None
        require(isinstance(observed, dict) and observed.get("ok") is True
                and observed.get("configuration_state") == configuration_state
                and type(observed.get("revision")) is int and observed.get("revision") == value["revision"]
                and actual_entries == expected_entries,
                "readback_failed", "运行适配器未完整读取新接口池")
        return observed

    def compatibility(self, value, secret, internal):
        primary = value["entries"][0]
        credentials = secret[primary["id"]]
        url = urllib.parse.urlsplit(primary["base_url"])
        host = "host.docker.internal" if url.hostname in ("127.0.0.1", "localhost") else url.hostname
        if ":" in host:
            host = "[" + host + "]"
        runtime_base = urllib.parse.urlunsplit((url.scheme, host + (":" + str(url.port) if url.port else ""), url.path, "", ""))
        values = {"PROVIDER_ADAPTER_KEY": internal, "PROVIDER_POOL_REQUIRED": "true", "PROVIDER_REQUIRE_ENVELOPE": "true",
                  "AI_API_BASE_URL": runtime_base, "AI_API_PROBE_BASE_URL": primary["base_url"], "AI_API_KEY": credentials["api_key"],
                  "AI_MODEL": primary["model"], "AI_API_MODE": primary["api_mode"], "AI_CUSTOM_HEADERS_JSON": json.dumps(credentials["custom_headers"], ensure_ascii=False, separators=(",", ":")),
                  "AI_SUPPORTS_VISION": str(primary["capabilities"]["vision"]).lower(), "AI_ANYTHINGLLM_BASE_URL": "http://provider-adapter:8787/v1",
                  "AI_MODEL_TOKEN_LIMIT": primary["context_window"], "AI_MAX_OUTPUT_TOKENS": primary["max_output_tokens"],
                  "PROVIDER_RAG_CONTEXT_WINDOW": rag_context_window(value)}
        atomic(self.env, env_text(self.env, values), 0o600)
        projection = dict(primary, type="openai-compatible", base_url=runtime_base, api_key_env="AI_API_KEY")
        for key in ("id", "role", "order", "enabled", "name"):
            projection.pop(key, None)
        atomic(self.root / "config/provider.yaml", {"schema_version": 2, "provider": projection})

    def restore_previous(self, saved, failed_revision, internal):
        restored = json.loads(saved[self.applied])
        require(restored.get("schema_version") == 1 and type(restored.get("revision")) is int and restored["revision"] > 0
                and re.fullmatch(r"[a-f0-9]{32}", restored.get("secrets_generation", "")), "invalid_pool", "历史接口池引用无效，不能执行恢复")
        generation = read(self.secrets / (restored["secrets_generation"] + ".json"), 16777216)
        require(generation.get("generation") == restored["secrets_generation"] and generation.get("revision") == restored["revision"], "invalid_pool", "历史接口池与秘密代次不一致")
        restored_secret = generation["entries"]
        self.validate(restored, restored_secret)
        restored["revision"] = failed_revision + 1
        restored["secrets_generation"] = secrets.token_hex(16)
        atomic(self.secrets / (restored["secrets_generation"] + ".json"), {"schema_version": 1, "generation": restored["secrets_generation"], "revision": restored["revision"], "entries": restored_secret})
        atomic(self.source, {key: content for key, content in restored.items() if key != "secrets_generation"})
        self.compatibility(restored, restored_secret, internal)
        atomic(self.applied, restored)
        return restored

    def apply_rag_window(self, window):
        command = ["bash", str(Path(__file__).resolve().with_name("provider.sh")), "--deploy-dir", str(self.root),
                   "internal-rag-context-apply", str(window)]
        try:
            descriptor = inherited_maintenance_descriptor(self.root / "tmp/maintenance.lock")
            completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=135, check=False,
                                       pass_fds=() if descriptor is None else (descriptor,))
            result = json.loads(completed.stdout)
            require(completed.returncode == 0 and isinstance(result, dict) and result.get("ok") is True
                    and result.get("state") == "applied" and type(result.get("context_window")) is int
                    and result["context_window"] == window, "rag_context_apply_failed", "知识预处理窗口应用或回读未通过")
            return result
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise PoolError("rag_context_apply_failed", "知识预处理窗口未能在限定时间内完成应用与回读") from None

    def transaction_update(self, transaction, **changes):
        observed = read(self.transaction)
        require(observed.get("token") == transaction["token"], "revision_conflict", "接口窗口事务已变更，不能覆盖其他操作")
        transaction.update(changes)
        atomic(self.transaction, transaction, 0o600)

    def transaction_clear(self, transaction):
        require(read(self.transaction).get("token") == transaction["token"], "revision_conflict", "接口窗口事务已变更，不能清理其他操作")
        self.transaction.unlink()
        descriptor = os.open(self.transaction.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def commit(self, value, secret, previous_revision, verify=True):
        with maintenance_lock(self.root):
            return self._commit(value, secret, previous_revision, verify)

    def _commit(self, value, secret, previous_revision, verify=True):
        directory(self.root / "config")
        directory(self.root / "secrets")
        directory(self.root / "secrets/provider")
        directory(self.secrets)
        directory(self.root / "data/provider-router", 0o700)
        directory(self.root / "backups/config-history/provider-pool")
        if os.geteuid() == 0:
            os.chown(self.root / "data/provider-router", 1000, 1000)
        lock_path = self.root / "config/provider-pool.lock"
        require(not lock_path.is_symlink(), "unsafe_file", "接口池锁不安全")
        window, transaction = rag_context_window(value), None
        with open(lock_path, "a", encoding="utf-8") as lock:
            os.chmod(lock_path, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = read(self.applied)["revision"] if self.applied.exists() else 0
            require(current == previous_revision, "revision_conflict", "接口池已被其他操作修改，请刷新后重试")
            require(not self.transaction.exists() and not self.transaction.is_symlink(), "configuration_applying", "接口窗口正在应用或等待恢复，请先恢复该事务")
            self.validate(value, secret)
            value["revision"] = current + 1
            generation = secrets.token_hex(16)
            value["secrets_generation"] = generation
            saved = {file: file.read_bytes() if file.exists() else None for file in (self.source, self.applied, self.env, self.root / "config/provider.yaml")}
            if saved[self.applied] is not None:
                previous = json.loads(saved[self.applied])
                atomic(self.root / "backups/config-history/provider-pool" / (str(previous["revision"]) + ".json"), previous)
            previous_env = read_env(self.env)
            internal = previous_env.get("PROVIDER_ADAPTER_KEY", "")
            require(current == 0 or internal not in [item["api_key"] for item in secret.values()], "invalid_key", "上游 Key 必须区别于受管内部认证")
            if not internal or re.match(r"^(replace-|change-me|not-configured)", internal, re.I) or internal in [item["api_key"] for item in secret.values()]:
                internal = secrets.token_hex(32)
            secret_path = self.secrets / (generation + ".json")
            publishing = False
            try:
                if verify and previous_env.get("PROVIDER_RAG_CONTEXT_WINDOW") != str(window):
                    require(current > 0, "invalid_configuration", "首次接口初始化应由完整安装流程启动组件")
                    transaction = {"schema_version": 1, "token": secrets.token_hex(16), "previous_revision": current,
                                   "revision": value["revision"], "previous_context_window": rag_context_window(previous),
                                   "context_window": window, "phase": "applying", "started_at": int(time.time() * 1000), **transaction_owner()}
                    atomic(self.transaction, transaction, 0o600)
                atomic(secret_path, {"schema_version": 1, "generation": generation, "revision": value["revision"], "entries": secret})
                source = {key: copy.deepcopy(content) for key, content in value.items() if key != "secrets_generation"}
                atomic(self.source, source)
                self.compatibility(value, secret, internal)
                publishing = True
                atomic(self.applied, value)
                observed, _ = self.load()
                require(observed == value, "readback_failed", "接口池回读不一致")
            except Exception:
                if publishing and saved[self.applied] is not None:
                    self.restore_previous(saved, value["revision"], internal)
                else:
                    for file, data in saved.items():
                        if data is not None:
                            atomic(file, data.decode("utf-8"), 0o600 if file == self.env else 0o640)
                        elif file.exists():
                            file.unlink()
                    if secret_path.exists():
                        secret_path.unlink()
                if transaction:
                    self.transaction_clear(transaction)
                raise
        # 锁外执行组件回读；配置事务从不持锁等待模型或网络。
        if verify:
            try:
                if transaction:
                    self.apply_rag_window(window)
                observed = self.adapter("status")
                self.verify_adapter_readback(value, observed, "applying" if transaction else "applied")
            except Exception as failure:
                with open(lock_path, "a", encoding="utf-8") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    require(read(self.applied)["revision"] == value["revision"], "revision_conflict", "运行回读期间接口池另有修改，请刷新检查当前配置")
                    restored = self.restore_previous(saved, value["revision"], internal)
                    if transaction:
                        self.transaction_update(transaction, phase="restoring", revision=restored["revision"], context_window=transaction["previous_context_window"], started_at=int(time.time() * 1000))
                if transaction:
                    try:
                        self.apply_rag_window(transaction["previous_context_window"])
                        self.verify_adapter_readback(restored, self.adapter("status"), "applying")
                    except Exception:
                        with open(lock_path, "a", encoding="utf-8") as lock:
                            fcntl.flock(lock, fcntl.LOCK_EX)
                            self.transaction_update(transaction, phase="restore_failed")
                        raise PoolError("rag_context_restore_failed", "原接口配置已恢复，但知识窗口尚未确认恢复；推理保持暂停，请执行 recover-rag-context") from None
                    with open(lock_path, "a", encoding="utf-8") as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        self.transaction_clear(transaction)
                code = failure.code if isinstance(failure, PoolError) else "readback_failed"
                raise PoolError(code, "组件应用或回读失败；原接口配置已以新代次恢复，旧请求保持取消") from None
            if transaction:
                with open(lock_path, "a", encoding="utf-8") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    require(read(self.applied)["revision"] == value["revision"], "revision_conflict", "接口窗口回读期间配置已变更")
                    self.transaction_clear(transaction)
        return dict(self.public(value), rag_context={"context_window": window, "state": "applied" if transaction else "unchanged" if verify else "deferred"})

    def recover_rag_context(self):
        if not self.transaction.exists() and not self.transaction.is_symlink():
            return {"ok": True, "restored": False, "message": "没有待恢复的知识上下文配置，未修改组件。"}
        with maintenance_lock(self.root):
            return self._recover_rag_context()

    def _recover_rag_context(self):
        lock_path = self.root / "config/provider-pool.lock"
        require(not lock_path.is_symlink(), "unsafe_file", "接口池锁不安全")
        with open(lock_path, "a", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            pending = read(self.transaction)
            require(pending.get("schema_version") == 1 and re.fullmatch(r"[a-f0-9]{32}", pending.get("token", ""))
                    and type(pending.get("previous_revision")) is int and pending["previous_revision"] > 0
                    and type(pending.get("owner_pid")) is int and pending["owner_pid"] > 0
                    and isinstance(pending.get("owner_boot_id"), str)
                    and re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", pending["owner_boot_id"])
                    and type(pending.get("owner_start_ticks")) is int and pending["owner_start_ticks"] > 0,
                    "invalid_configuration", "窗口恢复记录缺少可核对的进程身份")
            if process_identity(pending["owner_pid"]) == (pending["owner_boot_id"], pending["owner_start_ticks"]):
                raise PoolError("configuration_applying", "原窗口操作尚未结束，请等待其有界退出")
            require(pending.get("phase") == "restore_failed" or int(time.time() * 1000) >= pending.get("started_at", 0) + 140000,
                    "configuration_applying", "原窗口操作异常退出，仍需等待组件有界操作结束后恢复")
            old_file = self.root / "backups/config-history/provider-pool" / (str(pending["previous_revision"]) + ".json")
            regular(old_file)
            restored = self.restore_previous({self.applied: old_file.read_bytes()}, read(self.applied)["revision"], read_env(self.env)["PROVIDER_ADAPTER_KEY"])
            window = rag_context_window(restored)
            self.transaction_update(pending, phase="restoring", revision=restored["revision"], context_window=window, started_at=int(time.time() * 1000), **transaction_owner())
        try:
            self.apply_rag_window(window)
            self.verify_adapter_readback(restored, self.adapter("status"), "applying")
        except Exception:
            with open(lock_path, "a", encoding="utf-8") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.transaction_update(pending, phase="restore_failed")
            raise PoolError("rag_context_restore_failed", "窗口恢复尚未完成，推理继续暂停；可稍后再次执行 recover-rag-context") from None
        with open(lock_path, "a", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.transaction_clear(pending)
        return dict(self.public(restored), rag_context={"context_window": window, "state": "applied"})

    def migrate(self, defer_runtime=False):
        if defer_runtime:
            require(self.root.is_dir() and not self.root.is_symlink() and self.root.resolve() == self.root,
                    "unsafe_file", "受管安装目录必须是规范的实际目录")
            marker = self.root / ".crisp-ai-installation"
            regular(marker)
            lines = marker.read_text(encoding="utf-8").splitlines()
            states = [line.split("=", 1)[1] for line in lines if line.startswith("state=")]
            require(lines and lines[0] == "ai-support" and len(states) == 1 and states[0] in ("collecting", "installing", "staged"),
                    "invalid_installation_state", "仅受管安装或待启动阶段可延后知识窗口运行应用")
        if self.applied.exists():
            require(not self.transaction.exists() and not self.transaction.is_symlink(), "configuration_applying", "接口窗口存在未完成事务，请先执行 recover-rag-context")
            value, secret = self.load()
            # 已迁移的池为权威，不从可能陈旧的 AI_* 再生成或覆盖。
            internal = read_env(self.env).get("PROVIDER_ADAPTER_KEY", "")
            require(internal and internal not in [item["api_key"] for item in secret.values()], "internal_key_missing", "已迁移接口池缺少独立内部认证，请恢复受限环境配置")
            if read_env(self.env).get("PROVIDER_RAG_CONTEXT_WINDOW") != str(rag_context_window(value)):
                return self.commit(value, secret, value["revision"], verify=not defer_runtime)
            return dict(self.public(value), rag_context={"context_window": rag_context_window(value), "state": "deferred"}) if defer_runtime else self.public(value)
        require(not self.source.exists(), "invalid_pool", "已有主备池源但有效投影缺失，请恢复有效投影；不会用旧单接口覆盖")
        values = read_env(self.env)
        provider_file = self.root / "config/provider.yaml"
        legacy = read(provider_file).get("provider", {}) if provider_file.exists() else {}
        identifier = "p_" + secrets.token_hex(12)
        mode = legacy.get("api_mode") or values.get("AI_API_MODE") or "chat_completions"
        base = values.get("AI_API_PROBE_BASE_URL") or legacy.get("base_url") or values.get("AI_API_BASE_URL", "")
        capabilities = dict(legacy.get("capabilities") or {})
        for name in ("chat_completions", "responses", "vision"):
            capabilities.setdefault(name, mode == name if name != "vision" else values.get("AI_SUPPORTS_VISION") == "true")
        capabilities[mode] = True
        item = {"id": identifier, "name": "主接口", "role": "primary", "order": 0, "enabled": True,
                "base_url": base.rstrip("/"), "model": legacy.get("model") or values.get("AI_MODEL", ""), "api_mode": mode,
                "custom_header_names": [], "capabilities": capabilities, "context_window": int(values.get("AI_MODEL_TOKEN_LIMIT") or 8192),
                "max_output_tokens": int(values.get("AI_MAX_OUTPUT_TOKENS") or 1200)}
        secret = {identifier: {"api_key": values.get("AI_API_KEY", ""), "custom_headers": json.loads(values.get("AI_CUSTOM_HEADERS_JSON") or "{}")}}
        value = {"schema_version": 1, "revision": 0, "primary_id": identifier, "entries": [item], "policy": dict(POLICY)}
        return self.commit(value, secret, 0, verify=False)

    def adapter(self, action, payload=None):
        route = "/internal/provider/" + action
        method = "GET" if payload is None else "POST"
        override = os.environ.get("PROVIDER_ADAPTER_MANAGEMENT_URL")
        if override:
            url = urllib.parse.urlsplit(override)
            require(url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost", "::1") and not url.username and not url.password and not url.query and not url.fragment, "invalid_adapter", "本地适配器地址无效")
            internal = read_env(self.env).get("PROVIDER_ADAPTER_KEY", "")
            request = urllib.request.Request(override.rstrip("/") + route, data=json.dumps(payload).encode() if payload is not None else None,
                                             method=method, headers={"Content-Type": "application/json", "Authorization": "Bearer " + internal})
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    result = json.load(response)
            except urllib.error.HTTPError as error:
                try:
                    result = json.load(error)
                except (TypeError, ValueError):
                    raise PoolError("invalid_response", ADAPTER_FAILURES["invalid_response"][2]) from None
            except (OSError, urllib.error.URLError):
                raise PoolError("temporarily_unavailable", "本地适配器暂时不可用，原配置未更改", 4) from None
        else:
            code = "let s='';process.stdin.setEncoding('utf8');process.stdin.on('data',x=>s+=x);process.stdin.on('end',async()=>{try{const a=JSON.parse(s);const r=await fetch('http://127.0.0.1:8787'+a.route,{method:a.method,headers:{'content-type':'application/json',authorization:'Bearer '+process.env.PROVIDER_ADAPTER_KEY},signal:AbortSignal.timeout(26000),...(a.payload===null?{}:{body:JSON.stringify(a.payload)})});process.stdout.write(JSON.stringify(await r.json()));}catch(_){process.stdout.write(JSON.stringify({ok:false,error:{code:'temporarily_unavailable',message:'本地适配器暂时不可用'}}));process.exitCode=4;}});"
            command = ["docker", "compose", "--project-directory", str(self.root), "--env-file", str(self.env), "-f", str(self.root / "docker-compose.yml"), "exec", "-T", "provider-adapter", "node", "-e", code]
            try:
                completed = subprocess.run(command, input=json.dumps({"route": route, "method": method, "payload": payload}), text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=32, check=False)
                result = json.loads(completed.stdout)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                raise PoolError("temporarily_unavailable", "本地适配器暂时不可用，原配置未更改", 4) from None
        if not isinstance(result, dict):
            raise PoolError("invalid_response", ADAPTER_FAILURES["invalid_response"][2])
        if result.get("ok") is False or result.get("error"):
            detail = result.get("error")
            unsafe_code = detail.get("code") if isinstance(detail, dict) else "invalid_response"
            code = unsafe_code if isinstance(unsafe_code, str) and unsafe_code in ADAPTER_FAILURES else "provider_error"
            # /models 的普通 404/不支持端点允许手填；推理验证的同类响应则明确为协议问题。
            if action == "models" and (code in ("provider_error", "model_unavailable", "protocol_error")
                                       or unsafe_code == "invalid_request"):
                code = "models_unavailable"
            elif code == "provider_error" and unsafe_code == "invalid_request":
                code = "protocol_error"
            canonical, status, message = ADAPTER_FAILURES.get(
                code, ("provider_error", 1, "接口验证未通过；未采用上游返回的非受信任错误内容，原配置未更改"))
            failure = PoolError(canonical, message, status)
            retry_after = detail.get("retry_after_ms", 0) if isinstance(detail, dict) else 0
            failure.retry_after_ms = retry_after if type(retry_after) in (int, float) and 0 <= retry_after <= 86400000 else 0
            raise failure
        return result

    def candidate(self, value, secret, identifier, file=None):
        if identifier == "new":
            item = {"id": "p_" + secrets.token_hex(12), "name": "备用接口", "role": "backup", "order": len(value["entries"]), "enabled": True,
                    "base_url": "", "model": "", "api_mode": "chat_completions", "capabilities": {"chat_completions": True, "responses": False, "vision": False},
                    "custom_header_names": [], "context_window": 8192, "max_output_tokens": 1200}
            credentials = {"api_key": "", "custom_headers": {}}
        else:
            item = next((copy.deepcopy(item) for item in value["entries"] if item["id"] == identifier), None)
            require(item is not None, "entry_not_found", "接口不存在，请刷新列表")
            credentials = copy.deepcopy(secret[identifier])
        if file:
            data = read(Path(file))
            require(isinstance(data.get("provider"), dict), "invalid_input", "候选文件缺少 provider 对象")
            allowed = {"name", "base_url", "model", "api_mode", "custom_headers", "remove_header", "capabilities", "context_window", "max_output_tokens"}
            require(not (set(data["provider"]) - allowed), "invalid_input", "候选文件包含不支持的接口字段")
            for name, content in data["provider"].items():
                if name not in ("custom_headers", "remove_header"):
                    item[name] = content
            if data.get("api_key"):
                credentials["api_key"] = data["api_key"]
            credentials["custom_headers"].update(headers(data["provider"].get("custom_headers", {})))
            remove = data["provider"].get("remove_header")
            if remove:
                credentials["custom_headers"].pop(str(remove).lower(), None)
        item["base_url"] = str(item["base_url"]).rstrip("/")
        return item, credentials

    def probe(self, item, secret, vision=False, models=False):
        candidate = copy.deepcopy(item)
        candidate["custom_headers"] = secret["custom_headers"]
        if models and not candidate["model"]:
            candidate["model"] = "models-probe"
        modes = ["chat_completions"] if models else [candidate["api_mode"]] if candidate["api_mode"] != "auto" else ["chat_completions", "responses"]
        last = None
        for mode in modes:
            candidate["api_mode"] = mode
            entry(candidate, copy.deepcopy(secret))
            for attempt in range(3 if models else 1):
                try:
                    return self.adapter("models" if models else "probe", {"provider": candidate, "api_key": secret["api_key"], "vision": vision})
                except PoolError as error:
                    last = error
                    if error.code in ("authentication_failed", "safety_refusal"):
                        raise
                    if not models or error.status != 4 or attempt == 2 or error.code == "quota_exhausted":
                        break
                    delay = getattr(error, "retry_after_ms", 0)
                    if type(delay) not in (int, float) or delay < 0 or delay > 2000:
                        break
                    # 只读模型列表沿用三次有界重试，推理及验证绝不复用此循环。
                    time.sleep(max(delay / 1000, 0.2 * (2 ** attempt)))
        raise last

    def main(self, action, arguments, defer_runtime=False):
        readonly = {"list", "get", "show", "entry", "status", "recent", "models", "probe", "test", "vision-test",
                    "validate-file", "admin-marker", "draft", "draft-entry", "recover-rag-context"}
        if action in readonly or action == "policy" and not arguments:
            return self._main(action, arguments, defer_runtime)
        with maintenance_lock(self.root):
            return self._main(action, arguments, defer_runtime)

    def _main(self, action, arguments, defer_runtime=False):
        require(not defer_runtime or action == "migrate", "invalid_action", "延后组件应用仅用于受管安装迁移")
        if action == "recover-rag-context":
            return self.recover_rag_context()
        if action == "validate-file":
            checked = source_schema(read(Path(arguments[0])))
            return {"ok": True, "valid": True, "entries": len(checked["entries"]), "primary_id": checked["primary_id"]}
        if action == "migrate":
            return self.migrate(defer_runtime=defer_runtime)
        value, secret = self.load()
        if action in ("draft", "draft-entry", "edit-draft", "apply-draft"):
            draft, draft_secret = self.load_draft()
            if action == "draft":
                return dict(self.public(draft), applied=False, draft=True)
            if action in ("draft-entry", "edit-draft"):
                item, credentials = self.candidate(draft, draft_secret, arguments[0], arguments[1] if action == "edit-draft" else None)
                if action == "draft-entry":
                    item["key_status"] = "待填写" if item.get("draft") else "已保存"
                    return {"ok": True, "applied": False, "entry": item}
                verified = self.probe(item, credentials)
                if item["capabilities"]["vision"]:
                    self.probe(item, credentials, vision=True)
                item["api_mode"] = verified["api_mode"]
                item["capabilities"] = dict(verified["capabilities"], vision=item["capabilities"]["vision"])
                if item.pop("draft", False):
                    item["enabled"] = True
                entry(item, credentials)
                draft["entries"] = [item if current["id"] == item["id"] else current for current in draft["entries"]]
                draft_secret[item["id"]] = credentials
                return self.save_draft(draft, draft_secret)
            proposed = {key: copy.deepcopy(content) for key, content in draft.items() if key != "draft_secrets_generation"}
            source_schema(proposed)
            for item in proposed["entries"]:
                if item["enabled"]:
                    require(bool(draft_secret[item["id"]]["api_key"]), "invalid_key", "导入草稿仍有启用接口缺少 Key")
                    self.probe(item, draft_secret[item["id"]])
                    if item["capabilities"]["vision"]:
                        self.probe(item, draft_secret[item["id"]], vision=True)
            return self.commit(proposed, draft_secret, value["revision"])
        if action == "admin-marker":
            requested = int(arguments[0]) if arguments else value["policy"]["question_timeout_ms"]
            require(requested > 0, "invalid_input", "管理员测试时间预算必须大于零")
            material = self.root / "config/materials-applied.json"
            if material.exists():
                applied = read(material, 16777216)
                require(applied.get("state") == "applied", "configuration_applying", "客服配置尚未完成应用，不能开始管理员测试")
                runtime = applied["configuration"]["runtime"]
            else:
                runtime = read(self.root / "config/runtime.yaml")
            deadline = int(time.time() * 1000) + min(requested, value["policy"]["question_timeout_ms"])
            envelope = {"version": 1, "scope": "admin", "question_id": secrets.token_hex(32), "runtime_revision": runtime["revision"], "pool_revision": value["revision"], "deadline_at": deadline, "stage": "answer"}
            payload = base64.urlsafe_b64encode(json.dumps(envelope, separators=(",", ":")).encode()).decode().rstrip("=")
            internal = read_env(self.env).get("PROVIDER_ADAPTER_KEY", "")
            require(bool(internal), "internal_key_missing", "内部认证缺失")
            signature = hmac.new(internal.encode(), ("crispai-provider-v1\0" + payload).encode(), hashlib.sha256).hexdigest()
            return {"marker": "[[CRISPAI_PROVIDER_CONTEXT_V1:" + payload + "." + signature + "]]", "deadline_at": deadline}
        if action in ("get", "show", "list"):
            return self.public(value)
        if action == "entry":
            item, _ = self.candidate(value, secret, arguments[0])
            item["key_status"] = "待填写" if item.get("draft") else "已保存"
            return {"ok": True, "revision": value["revision"], "entry": item}
        if action in ("status", "recent"):
            return self.adapter(action)
        if action in ("models", "probe", "test", "vision-test"):
            identifier = arguments[0] if arguments else value["primary_id"]
            file = arguments[1] if len(arguments) > 1 else None
            if identifier != "new" and not IDENTIFIER.fullmatch(identifier):
                file, identifier = identifier, value["primary_id"]
            item, credentials = self.candidate(value, secret, identifier, file)
            result = self.probe(item, credentials, vision=action == "vision-test", models=action == "models")
            if action != "models":
                result["id"] = item["id"]
            return result
        if action == "policy" and not arguments:
            return {"ok": True, "policy": value["policy"]}
        revision = value["revision"]
        if action in ("apply-file", "import"):
            proposed = source_schema(read(Path(arguments[0])))
            proposed_secret = {item["id"]: copy.deepcopy(secret.get(item["id"], {"api_key": "", "custom_headers": {}})) for item in proposed["entries"]}
            if action == "import" and not proposed_secret[proposed["primary_id"]]["api_key"]:
                draft = copy.deepcopy(proposed)
                for item in draft["entries"]:
                    if not proposed_secret[item["id"]]["api_key"]:
                        item["draft"], item["enabled"] = True, False
                draft["revision"] = value["revision"]
                return self.save_draft(draft, proposed_secret)
            previous_entries = {item["id"]: item for item in value["entries"]}
            for item in proposed["entries"]:
                credentials = proposed_secret[item["id"]]
                if not credentials["api_key"]:
                    require(action == "import" or item.get("draft") is True and not item["enabled"], "invalid_key", "新增接口未有本机 Key，请先通过新增接口保存凭据")
                    item["draft"], item["enabled"] = True, False
                if item["enabled"] and item != previous_entries.get(item["id"]):
                    verified = self.probe(item, credentials)
                    if item["capabilities"]["vision"]:
                        self.probe(item, credentials, vision=True)
                    item["capabilities"] = dict(verified["capabilities"], vision=item["capabilities"]["vision"])
            value, secret = proposed, proposed_secret
        elif action in ("add", "edit", "apply"):
            require(action != "add" or len(value["entries"]) < 21, "pool_capacity", "接口池最多21个接口，停用接口仍占名额")
            identifier = "new" if action == "add" else value["primary_id"] if action == "apply" else arguments[0]
            file = arguments[0] if action in ("add", "apply") else arguments[1]
            item, credentials = self.candidate(value, secret, identifier, file)
            result = self.probe(item, credentials)
            vision = item["capabilities"]["vision"]
            if vision:
                self.probe(dict(item, api_mode=result["api_mode"]), credentials, vision=True)
            item["api_mode"] = result["api_mode"]
            item["capabilities"] = dict(result["capabilities"], vision=vision)
            item.pop("draft", None)
            entry(item, credentials)
            if action == "add":
                value["entries"].append(item)
            else:
                value["entries"] = [item if old["id"] == identifier else old for old in value["entries"]]
            secret[item["id"]] = credentials
        elif action in ("primary", "enable", "delete"):
            identifier = arguments[0]
            item, _ = self.candidate(value, secret, identifier)
            if action == "primary":
                if identifier != value["primary_id"]:
                    self.probe(item, secret[identifier])
                    if item["capabilities"]["vision"]:
                        self.probe(item, secret[identifier], vision=True)
                previous = value["entries"].index(next(current for current in value["entries"] if current["id"] == identifier))
                value["entries"][0], value["entries"][previous] = value["entries"][previous], value["entries"][0]
                value["entries"][0]["enabled"] = True
                value["primary_id"] = identifier
            elif action == "delete":
                require(identifier != value["primary_id"], "primary_required", "不能删除主接口，请先设置其他主接口")
                value["entries"] = [current for current in value["entries"] if current["id"] != identifier]
                del secret[identifier]
            else:
                require(len(arguments) > 1 and arguments[1] in ("true", "false"), "invalid_input", "启用状态必须为 true 或 false")
                require(identifier != value["primary_id"] or arguments[1] == "true", "primary_required", "不能停用主接口，请先设置其他主接口")
                if arguments[1] == "true" and not item["enabled"]:
                    require(not item.get("draft"), "invalid_key", "接口尚未填写 Key，请先编辑接口并验证")
                    self.probe(item, secret[identifier])
                    if item["capabilities"]["vision"]:
                        self.probe(item, secret[identifier], vision=True)
                for current in value["entries"]:
                    if current["id"] == identifier:
                        current["enabled"] = arguments[1] == "true"
        elif action == "order":
            order = read(Path(arguments[0])).get("ids")
            require(isinstance(order, list) and len(set(order)) == len(order) and set(order) == {item["id"] for item in value["entries"][1:]}, "invalid_order", "排序必须包含全部备用接口且不得重复")
            value["entries"] = [value["entries"][0]] + [next(item for item in value["entries"] if item["id"] == identifier) for identifier in order]
        elif action == "policy":
            proposed = read(Path(arguments[0]))
            value["policy"] = policy(dict(value["policy"], **proposed.get("policy", proposed)))
        else:
            raise PoolError("invalid_action", "不支持的主备管理操作")
        for index, item in enumerate(value["entries"]):
            item["order"], item["role"] = index, "primary" if index == 0 else "backup"
        return self.commit(value, secret, revision)


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--deploy-dir", required=True)
    parser.add_argument("--defer-runtime", action="store_true")
    parser.add_argument("action", nargs="?", default="list")
    parser.add_argument("arguments", nargs="*")
    options = parser.parse_args()
    try:
        result = Manager(options.deploy_dir).main(options.action, options.arguments, defer_runtime=options.defer_runtime)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except PoolError as error:
        print(json.dumps({"ok": False, "error": {"code": error.code, "message": str(error)}}, ensure_ascii=False))
        return error.status
    except Exception:
        print(json.dumps({"ok": False, "error": {"code": "invalid_configuration", "message": "受管配置缺失、格式无效或无法安全读写；原配置未提交"}}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
