#!/usr/bin/env python3
"""受管主备接口池：非敏感配置、不可变秘密代次与原子发布。"""

import argparse
import base64
import copy
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


class PoolError(Exception):
    def __init__(self, code, message, status=1):
        super().__init__(message)
        self.code, self.status = code, status


def require(condition, code, message):
    if not condition:
        raise PoolError(code, message)


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


def entry(value, secret):
    require(isinstance(value, dict) and IDENTIFIER.fullmatch(value.get("id", "")) and type(value.get("enabled")) is bool,
            "invalid_entry", "接口标识或启用状态无效")
    require(isinstance(value.get("name"), str) and 0 < len(value["name"]) <= 80 and not re.search(r"[\x00-\x1f\x7f]", value["name"]), "invalid_entry", "接口名称无效")
    require(isinstance(value.get("base_url"), str) and len(value["base_url"]) <= 4096, "invalid_url", "接口地址无效")
    url = urllib.parse.urlsplit(value["base_url"])
    require(url.scheme in ("https", "http") and url.hostname and not url.username and not url.password and not url.query and not url.fragment
            and not re.search(r"[\x00-\x20\x7f]", value["base_url"]) and (url.scheme != "http" or url.hostname in ("127.0.0.1", "localhost", "host.docker.internal", "::1")), "invalid_url", "接口地址必须为安全地址；明文仅限受管本机网关")
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


class Manager:
    def __init__(self, root):
        self.root = Path(root).absolute()
        self.source = self.root / "config/provider-pool.yaml"
        self.applied = self.root / "config/provider-pool-applied.json"
        self.secrets = self.root / "secrets/provider/generations"
        self.env = self.root / ".env"

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

    def compatibility(self, value, secret, internal):
        primary = value["entries"][0]
        credentials = secret[primary["id"]]
        url = urllib.parse.urlsplit(primary["base_url"])
        host = "host.docker.internal" if url.hostname in ("127.0.0.1", "localhost") else url.hostname
        runtime_base = urllib.parse.urlunsplit((url.scheme, host + (":" + str(url.port) if url.port else ""), url.path, "", ""))
        values = {"PROVIDER_ADAPTER_KEY": internal, "PROVIDER_POOL_REQUIRED": "true", "PROVIDER_REQUIRE_ENVELOPE": "true",
                  "AI_API_BASE_URL": runtime_base, "AI_API_PROBE_BASE_URL": primary["base_url"], "AI_API_KEY": credentials["api_key"],
                  "AI_MODEL": primary["model"], "AI_API_MODE": primary["api_mode"], "AI_CUSTOM_HEADERS_JSON": json.dumps(credentials["custom_headers"], ensure_ascii=False, separators=(",", ":")),
                  "AI_SUPPORTS_VISION": str(primary["capabilities"]["vision"]).lower(), "AI_ANYTHINGLLM_BASE_URL": "http://provider-adapter:8787/v1"}
        atomic(self.env, env_text(self.env, values), 0o600)
        projection = dict(primary, type="openai-compatible", base_url=runtime_base, api_key_env="AI_API_KEY")
        for key in ("id", "role", "order", "enabled", "name"):
            projection.pop(key, None)
        atomic(self.root / "config/provider.yaml", {"schema_version": 2, "provider": projection})

    def restore_previous(self, saved, failed_revision, internal):
        restored = json.loads(saved[self.applied])
        restored_secret = read(self.secrets / (restored["secrets_generation"] + ".json"), 16777216)["entries"]
        restored["revision"] = failed_revision + 1
        restored["secrets_generation"] = secrets.token_hex(16)
        atomic(self.secrets / (restored["secrets_generation"] + ".json"), {"schema_version": 1, "generation": restored["secrets_generation"], "revision": restored["revision"], "entries": restored_secret})
        atomic(self.source, {key: content for key, content in restored.items() if key != "secrets_generation"})
        self.compatibility(restored, restored_secret, internal)
        atomic(self.applied, restored)

    def commit(self, value, secret, previous_revision, verify=True):
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
        with open(lock_path, "a", encoding="utf-8") as lock:
            os.chmod(lock_path, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = read(self.applied)["revision"] if self.applied.exists() else 0
            require(current == previous_revision, "revision_conflict", "接口池已被其他操作修改，请刷新后重试")
            self.validate(value, secret)
            value["revision"] = current + 1
            generation = secrets.token_hex(16)
            value["secrets_generation"] = generation
            saved = {file: file.read_bytes() if file.exists() else None for file in (self.source, self.applied, self.env, self.root / "config/provider.yaml")}
            if saved[self.applied] is not None:
                previous = json.loads(saved[self.applied])
                atomic(self.root / "backups/config-history/provider-pool" / (str(previous["revision"]) + ".json"), previous)
            internal = read_env(self.env).get("PROVIDER_ADAPTER_KEY", "")
            require(current == 0 or internal not in [item["api_key"] for item in secret.values()], "invalid_key", "上游 Key 必须区别于受管内部认证")
            if not internal or re.match(r"^(replace-|change-me|not-configured)", internal, re.I) or internal in [item["api_key"] for item in secret.values()]:
                internal = secrets.token_hex(32)
            secret_path = self.secrets / (generation + ".json")
            publishing = False
            try:
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
                raise
        # 锁外执行组件回读；配置事务从不持锁等待模型或网络。
        if verify:
            try:
                observed = self.adapter("status")
                require(observed.get("revision") == value["revision"], "readback_failed", "运行适配器未读取到新接口池")
            except Exception:
                with open(lock_path, "a", encoding="utf-8") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    if read(self.applied)["revision"] == value["revision"]:
                        self.restore_previous(saved, value["revision"], internal)
                        raise PoolError("readback_failed", "运行适配器回读失败；原接口配置已以新代次恢复，旧请求保持取消")
                raise PoolError("revision_conflict", "运行回读期间接口池另有修改，请刷新检查当前配置")
        return self.public(value)

    def migrate(self):
        if self.applied.exists():
            value, secret = self.load()
            # 已迁移的池为权威，不从可能陈旧的 AI_* 再生成或覆盖。
            internal = read_env(self.env).get("PROVIDER_ADAPTER_KEY", "")
            require(internal and internal not in [item["api_key"] for item in secret.values()], "internal_key_missing", "已迁移接口池缺少独立内部认证，请恢复受限环境配置")
            return self.public(value)
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
                result = json.load(error)
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
        if result.get("ok") is False or result.get("error"):
            code = result.get("error", {}).get("code", "provider_error")
            if code == "authentication_failed":
                raise PoolError(code, "接口认证失败，请检查凭据与权限", 3)
            if code in ("upstream_timeout", "upstream_unavailable", "rate_limited", "connection_failed", "temporarily_unavailable", "quota_exhausted"):
                failure = PoolError("temporarily_unavailable", "接口暂时不可用，请稍后重试或检查额度", 4)
                failure.retry_after_ms = result.get("error", {}).get("retry_after_ms", 0)
                failure.upstream_code = code
                raise failure
            if action == "models":
                raise PoolError("models_unavailable", "接口未提供可用模型列表，可以手动填写模型", 2)
            raise PoolError(code, "接口验证未通过，原配置未更改")
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
                    if not models or error.status != 4 or attempt == 2 or getattr(error, "upstream_code", "") == "quota_exhausted":
                        break
                    delay = getattr(error, "retry_after_ms", 0)
                    if type(delay) not in (int, float) or delay < 0 or delay > 2000:
                        break
                    # 只读模型列表沿用三次有界重试，推理及验证绝不复用此循环。
                    time.sleep(max(delay / 1000, 0.2 * (2 ** attempt)))
        raise last

    def main(self, action, arguments):
        if action == "validate-file":
            checked = source_schema(read(Path(arguments[0])))
            return {"ok": True, "valid": True, "entries": len(checked["entries"]), "primary_id": checked["primary_id"]}
        if action == "migrate":
            return self.migrate()
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
    parser.add_argument("action", nargs="?", default="list")
    parser.add_argument("arguments", nargs="*")
    options = parser.parse_args()
    try:
        result = Manager(options.deploy_dir).main(options.action, options.arguments)
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
