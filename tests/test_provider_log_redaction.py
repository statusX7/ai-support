#!/usr/bin/env python3
"""主备池日志秘密隔离回归；只生成虚构凭据，不连接任何部署实例。"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote, quote_plus


ROOT = Path(__file__).resolve().parents[1]
REDACTOR = ROOT / "scripts/log-redact.py"
GENERATION_NAMES = ("a" * 32 + ".json", "b" * 32 + ".json", "draft-" + "c" * 32 + ".json")


class TestFailure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise TestFailure(message)


def fabricated(label: str) -> str:
    return f'fixture-pool-{label}-探针🧭 /+="\\tail space'


def pool_values() -> list[str]:
    return [
        fabricated(f"{generation}-{field}")
        for generation in ("active", "history", "draft")
        for field in ("key", "header")
    ]


def encoded_variants(value: str) -> set[str]:
    raw = value.encode("utf-8")
    single_url = {quote(value, safe=""), quote_plus(value, safe="")}
    single_url.update(re.sub(r"%[0-9A-F]{2}", lambda match: match[0].lower(), item) for item in list(single_url))
    variants = {
        value,
        json.dumps(value, ensure_ascii=False)[1:-1],
        json.dumps(value, ensure_ascii=True)[1:-1],
        quote(value, safe=""),
        quote(quote(value, safe=""), safe=""),
        quote_plus(value, safe=""),
        base64.b64encode(raw).decode("ascii"),
        base64.urlsafe_b64encode(raw).decode("ascii"),
        base64.urlsafe_b64encode(raw).decode("ascii").rstrip("="),
    }
    variants.update(single_url)
    variants.update(quote(item, safe="") for item in single_url)
    variants.update(re.sub(r"%[0-9A-F]{2}", lambda match: match[0].lower(), item) for item in list(variants))
    return variants


def all_pool_variants() -> set[str]:
    return {variant for value in pool_values() for variant in encoded_variants(value)}


def write_generation(file: Path, key: str, header: str = "") -> None:
    file.write_text(
        json.dumps({"entries": {"fixture": {"api_key": key, "custom_headers": {"X-Fixture": header}}}}, ensure_ascii=False),
        encoding="utf-8",
    )
    file.chmod(0o600)


def write_pool_fixture(root: Path) -> list[Path]:
    """也供生产 logs export 的隔离 shell 测试复用同一组虚构代次。"""
    directory = root / "secrets/provider/generations"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    values = pool_values()
    files = []
    for index, name in enumerate(GENERATION_NAMES):
        file = directory / name
        write_generation(file, values[index * 2], values[index * 2 + 1])
        files.append(file)
    return files


def write_env(root: Path, primary: str | None = None) -> Path:
    env = root / ".env"
    value = fabricated("primary") if primary is None else primary
    env.write_text("AI_API_KEY=" + json.dumps(value) + "\nPROVIDER_ADAPTER_KEY=fixture-internal-channel-only\n", encoding="utf-8")
    env.chmod(0o600)
    return env


def load_redactor():
    spec = importlib.util.spec_from_file_location("crispai_test_log_redact", REDACTOR)
    require(spec is not None and spec.loader is not None, "无法加载生产脱敏模块")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_filter(env: Path, content: str, mode: str = "display"):
    return subprocess.run(
        [sys.executable, str(REDACTOR), "--env", str(env), "--mode", mode],
        input=content, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=4, check=False,
    )


def assert_rejected(env: Path, label: str) -> None:
    canary = fabricated("primary")
    try:
        result = run_filter(env, canary + "\n")
    except subprocess.TimeoutExpired as error:
        raise TestFailure(f"{label} 读取超过有界期限") from error
    require(result.returncode != 0, f"{label} 未失败关闭")
    require(result.stdout == "", f"{label} 在秘密清单异常时仍输出日志")
    require("Traceback" not in result.stderr and canary not in result.stderr, f"{label} 错误说明泄漏原文或调用栈")
    require("已停止日志输出" in result.stderr, f"{label} 缺少明确中文错误说明")


def test_generations_and_encodings() -> None:
    module = load_redactor()
    with tempfile.TemporaryDirectory(prefix="crispai-pool-redact-") as temporary:
        root = Path(temporary)
        env = write_env(root)
        files = write_pool_fixture(root)
        before = {file: file.read_bytes() for file in [env, *files]}
        variants = all_pool_variants() | encoded_variants(fabricated("primary"))
        payload = "".join("probe " + value + "\n" for value in sorted(variants))
        # 负对照明确模拟只查 .env 的旧收集范围，不冒称执行历史正式包。
        env_only = module.collect_secrets(module.parse_env(env))
        control = "\n".join(module.redact_line(line, env_only, "display") for line in payload.splitlines())
        require(all(value in control for value in all_pool_variants()), "负对照未保留池凭据，样例可能被通用正则提前处理")
        for mode in ("display", "export"):
            result = run_filter(env, payload, mode)
            require(result.returncode == 0, f"{mode} 正常代次脱敏失败")
            require(not result.stderr, f"{mode} 正常代次出现错误说明")
            require(not any(value in result.stdout for value in variants), f"{mode} 遗漏池或主接口编码")
            require(result.stdout.count("[已脱敏]") == len(variants), f"{mode} 未逐条保留可读的脱敏结果")
        require(all(file.read_bytes() == data for file, data in before.items()), "日志读取改写了秘密原件")


def test_legacy_without_pool() -> None:
    with tempfile.TemporaryDirectory(prefix="crispai-pool-absent-") as temporary:
        root = Path(temporary)
        env = write_env(root)
        result = run_filter(env, "ordinary operational line\n")
        require(result.returncode == 0 and result.stdout == "ordinary operational line\n", "没有池目录的旧实例不能安全查看日志")
        require(not (root / "secrets").exists(), "只读日志创建了池或秘密目录")


class Follow:
    def __init__(self, env: Path):
        environment = dict(os.environ)
        environment.pop("PYTHONUNBUFFERED", None)
        self.process = subprocess.Popen(
            [sys.executable, str(REDACTOR), "--env", str(env)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment,
        )
        self.buffer = b""

    def send(self, value: str) -> None:
        require(self.process.stdin is not None, "跟踪输入不可用")
        self.process.stdin.write((value + "\n").encode())
        self.process.stdin.flush()

    def line(self) -> str:
        deadline = time.monotonic() + 3
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "跟踪输入未关闭时输出仍被缓冲")
            readable, _, _ = select.select([self.process.stdout], [], [], remaining)
            require(bool(readable), "跟踪输出超过有界等待")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            require(bool(chunk), "跟踪在输出记录前异常退出")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.decode("utf-8")

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=3)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


def test_follow_rotation() -> None:
    with tempfile.TemporaryDirectory(prefix="crispai-pool-follow-") as temporary:
        root = Path(temporary)
        env = write_env(root)
        files = write_pool_fixture(root)
        follow = Follow(env)
        try:
            follow.send(pool_values()[0])
            require(follow.line() == "[已脱敏]", "跟踪首条没有立即脱敏")
            new_value = fabricated("rotated")
            new_file = files[0].parent / ("d" * 32 + ".json")
            write_generation(new_file, new_value)
            follow.send(new_value)
            require(follow.line() == "[已脱敏]", "跟踪未纳入新有效代次")
            new_draft = fabricated("rotated-draft")
            write_generation(files[0].parent / ("draft-" + "e" * 32 + ".json"), new_draft)
            follow.send(new_draft)
            require(follow.line() == "[已脱敏]", "跟踪未纳入新导入草稿")
            follow.send(pool_values()[2])
            require(follow.line() == "[已脱敏]", "轮换后遗漏仍保留的历史代次")

            # 原子替换即使保留大小和 mtime，也必须因 inode/ctime 改变重新读取。
            original = files[0].stat()
            replacement = files[0].with_suffix(".pending")
            changed = pool_values()[0].replace("active", "latest")
            write_generation(replacement, changed, pool_values()[1])
            require(replacement.stat().st_size == original.st_size, "同大小轮换样例无效")
            os.utime(replacement, ns=(original.st_atime_ns, original.st_mtime_ns))
            replacement.replace(files[0])
            follow.send(changed)
            require(follow.line() == "[已脱敏]", "保留 mtime 的原子代次替换未刷新")

            original_env = env.stat()
            new_primary = fabricated("another")
            env_pending = root / ".env.pending"
            # .env 使用 JSON 转义；通过编码后的同长度值替换，避免伪轮换。
            env_pending.write_text(env.read_text().replace(json.dumps(fabricated("primary")), json.dumps(new_primary)), encoding="utf-8")
            require(env_pending.stat().st_size == original_env.st_size, "主接口同大小轮换样例无效")
            os.utime(env_pending, ns=(original_env.st_atime_ns, original_env.st_mtime_ns))
            env_pending.replace(env)
            follow.send(new_primary)
            require(follow.line() == "[已脱敏]", "保留 mtime 的主接口原子轮换未刷新")

            follow.process.send_signal(signal.SIGINT)
            require(follow.process.wait(timeout=3) == 130, "跟踪 Ctrl+C 未按约定退出")
            require(b"Traceback" not in follow.process.stderr.read(), "跟踪 Ctrl+C 泄漏调用栈")
        finally:
            follow.close()


def test_pool_invalid_documents() -> None:
    documents = {
        "无效 JSON": b"{not-json",
        "无效 UTF-8": b"\xff",
        "顶层非对象": b"[]",
        "缺少 entries": b"{}",
        "entries 非对象": b'{"entries":[]}',
        "条目非对象": b'{"entries":{"fixture":[]}}',
        "Key 缺失": b'{"entries":{"fixture":{}}}',
        "Key 非字符串": b'{"entries":{"fixture":{"api_key":false}}}',
        "Header 非对象": b'{"entries":{"fixture":{"api_key":"","custom_headers":[]}}}',
        "Header 值非字符串": b'{"entries":{"fixture":{"api_key":"","custom_headers":{"X-Fixture":1}}}}',
        "条目超过 21": json.dumps({"entries": {str(index): {"api_key": ""} for index in range(22)}}).encode(),
    }
    for label, data in documents.items():
        with tempfile.TemporaryDirectory(prefix="crispai-pool-invalid-") as temporary:
            root = Path(temporary)
            env = write_env(root)
            file = write_pool_fixture(root)[0]
            file.write_bytes(data)
            assert_rejected(env, label)


def test_pool_unsafe_files() -> None:
    for kind in ("symlink", "hardlink", "fifo", "directory", "oversize"):
        with tempfile.TemporaryDirectory(prefix="crispai-pool-file-") as temporary:
            root = Path(temporary)
            env = write_env(root)
            file = write_pool_fixture(root)[0]
            if kind in ("symlink", "hardlink"):
                original = file.with_suffix(".retained")
                file.replace(original)
                file.symlink_to(original) if kind == "symlink" else os.link(original, file)
            elif kind == "oversize":
                with file.open("wb") as stream:
                    stream.truncate(16 * 1024 * 1024 + 1)
            else:
                file.unlink()
                os.mkfifo(file) if kind == "fifo" else file.mkdir()
            assert_rejected(env, "池文件 " + kind)
    for depth in range(3):
        for kind in ("symlink", "not_directory"):
            with tempfile.TemporaryDirectory(prefix="crispai-pool-directory-") as temporary:
                root = Path(temporary)
                env = write_env(root)
                directory = root.joinpath(*("secrets", "provider", "generations")[:depth + 1])
                directory.parent.mkdir(parents=True, exist_ok=True)
                if kind == "symlink":
                    destination = root / "unmanaged"
                    destination.mkdir()
                    directory.symlink_to(destination, target_is_directory=True)
                else:
                    directory.write_text("fixture")
                assert_rejected(env, f"池目录层 {depth + 1} {kind}")


def expect_inventory_rejected(module, env: Path, message: str) -> None:
    try:
        module.provider_secret_files(env)
    except (OSError, ValueError):
        return
    raise TestFailure(message)


def test_inventory_bounds() -> None:
    module = load_redactor()
    with tempfile.TemporaryDirectory(prefix="crispai-pool-count-") as temporary:
        root = Path(temporary)
        env = write_env(root)
        directory = root / "secrets/provider/generations"
        directory.mkdir(parents=True)
        for index in range(4096):
            (directory / f"{index:032x}.json").touch(mode=0o600)
        require(len(module.provider_secret_files(env)) == 4096, "文件数量合法上限被误拒绝")
        (directory / f"{4096:032x}.json").touch(mode=0o600)
        expect_inventory_rejected(module, env, "超过 4096 代次未拒绝")
    with tempfile.TemporaryDirectory(prefix="crispai-pool-total-") as temporary:
        root = Path(temporary)
        env = write_env(root)
        directory = root / "secrets/provider/generations"
        directory.mkdir(parents=True)
        for index in range(4):
            with (directory / f"{index:032x}.json").open("wb") as stream:
                stream.truncate(16 * 1024 * 1024)
        require(len(module.provider_secret_files(env)) == 4, "总大小合法上限被误拒绝")
        (directory / f"{4:032x}.json").write_bytes(b"x")
        expect_inventory_rejected(module, env, "超过 64 MiB 总量未拒绝")


def test_env_invalid() -> None:
    for kind in ("missing", "symlink", "hardlink", "fifo", "directory", "oversize", "utf8", "quote", "duplicate", "invalid_line", "headers"):
        with tempfile.TemporaryDirectory(prefix="crispai-pool-env-") as temporary:
            root = Path(temporary)
            env = write_env(root)
            if kind in ("symlink", "hardlink"):
                original = root / ".env.retained"
                env.replace(original)
                env.symlink_to(original) if kind == "symlink" else os.link(original, env)
            elif kind in ("missing", "fifo", "directory"):
                env.unlink()
                if kind == "fifo":
                    os.mkfifo(env)
                elif kind == "directory":
                    env.mkdir()
            elif kind == "oversize":
                with env.open("ab") as stream:
                    stream.truncate(1024 * 1024 + 1)
            elif kind == "utf8":
                with env.open("ab") as stream:
                    stream.write(b"\xff")
            elif kind == "quote":
                env.write_text('AI_API_KEY="fixture-invalid-json\\q"\n')
            elif kind == "duplicate":
                with env.open("a") as stream:
                    stream.write("AI_API_KEY=fixture-other-value\n")
            elif kind == "invalid_line":
                with env.open("a") as stream:
                    stream.write("this is not an assignment\n")
            elif kind == "headers":
                with env.open("a") as stream:
                    stream.write("AI_CUSTOM_HEADERS_JSON=not-json\n")
            assert_rejected(env, ".env " + kind)


def test_follow_invalid_rotation() -> None:
    for kind in ("pool", "env"):
        with tempfile.TemporaryDirectory(prefix="crispai-pool-follow-bad-") as temporary:
            root = Path(temporary)
            env = write_env(root)
            files = write_pool_fixture(root)
            follow = Follow(env)
            try:
                follow.send("safe initial record")
                require(follow.line() == "safe initial record", "异常轮换的前置跟踪失败")
                if kind == "pool":
                    (files[0].parent / ("e" * 32 + ".json")).write_text("invalid-json")
                else:
                    original = root / ".env.retained"
                    env.replace(original)
                    env.symlink_to(original)
                follow.send(fabricated("primary"))
                require(follow.process.wait(timeout=3) != 0, f"{kind} 异常轮换未停止输出")
                require(not follow.buffer and follow.process.stdout.read() == b"", f"{kind} 异常轮换继续输出待过滤记录")
                error = follow.process.stderr.read().decode()
                require("已停止日志输出" in error and "Traceback" not in error, f"{kind} 异常轮换错误说明不安全")
            finally:
                follow.close()


def main() -> int:
    tests = (
        ("有效、历史及草稿 Key/Header 原文和常见编码，含旧范围负对照", test_generations_and_encodings),
        ("无池旧实例兼容且不创建配置", test_legacy_without_pool),
        ("非 TTY 跟踪即时刷新、新代次及同 mtime 原子轮换", test_follow_rotation),
        ("11 类无效代次结构失败关闭", test_pool_invalid_documents),
        ("池文件与三层目录的链接、类型及大小拒绝", test_pool_unsafe_files),
        ("4096 文件与 64 MiB 聚合上限", test_inventory_bounds),
        ("11 类 .env 异常失败关闭", test_env_invalid),
        ("跟踪期间池或 .env 异常停止输出", test_follow_invalid_rotation),
    )
    passed = failed = 0
    for label, test in tests:
        try:
            test()
        except TestFailure as error:
            failed += 1
            print(f"失败：[UNIT/CONTRACT] {label}：{error}", file=sys.stderr, flush=True)
        except Exception as error:
            failed += 1
            print(f"失败：[UNIT/CONTRACT] {label}：测试异常类型 {type(error).__name__}", file=sys.stderr, flush=True)
        else:
            passed += 1
            print(f"通过：[UNIT/CONTRACT] {label}", flush=True)
    print(f"主备池日志秘密专项：{passed} 组通过，{failed} 组失败；仅虚构本地样例。", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
