#!/usr/bin/env python3
"""发布门禁负例：使用独立临时 Git 和假资产，不运行网络或发布命令。"""

import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_gate", ROOT / "scripts/release-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def run(arguments, cwd, **kwargs):
    return subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, timeout=10, **kwargs)


def main():
    with tempfile.TemporaryDirectory(prefix=".test-runtime.release-gate.", dir=ROOT) as name:
        temporary = Path(name)
        source = temporary / "source"
        source.mkdir()
        (source / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/release-gate.py", source / "scripts/release-gate.py")
        (source / "VERSION").write_text("v1.2.1\n", encoding="utf-8")
        (source / "get.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        for command in (
            ["git", "init", "--quiet"], ["git", "add", "."],
            ["git", "-c", "user.name=Contract Test", "-c", "user.email=contract@example.invalid", "commit", "--quiet", "-m", "v1.2.1 gate fixture"],
        ):
            assert run(command, source).returncode == 0
        commit = run(["git", "rev-parse", "HEAD"], source).stdout.strip()
        artifacts = temporary / "artifacts"
        artifacts.mkdir()
        archive = artifacts / "ai-support-v1.2.1.tar.gz"
        original = b"synthetic gate contract asset, never installed or published\n"
        archive.write_bytes(original)
        digest = hashlib.sha256(original).hexdigest()
        checksum = artifacts / "SHA256SUMS"
        checksum.write_text(digest + "  " + archive.name + "\n", encoding="ascii")
        shutil.copy2(source / "get.sh", artifacts / "get.sh")
        receipt = temporary / "receipt.json"
        accepted = {
            "schema_version": 1, "version": "v1.2.1", "commit": commit,
            "archive_sha256": digest, "target_alias": "TARGET-A",
            "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "checks": dict.fromkeys(gate.CHECKS, True),
        }
        called = temporary / "publish-called"
        invoke = [
            "bash", "-c",
            'python3 "$1" --artifacts "$2" --target-receipt "$3" && printf invoked > "$4"',
            "gate-test", str(source / "scripts/release-gate.py"), str(artifacts), str(receipt), str(called),
        ]
        passed = 0

        def save(record=None):
            if receipt.exists() or receipt.is_symlink():
                receipt.unlink()
            receipt.write_text(json.dumps(accepted if record is None else record), encoding="utf-8")
            receipt.chmod(0o600)

        def save_raw(contents):
            if receipt.exists() or receipt.is_symlink():
                receipt.unlink()
            receipt.write_text(contents, encoding="utf-8")
            receipt.chmod(0o600)

        def check(label, allowed=False):
            nonlocal passed
            called.unlink(missing_ok=True)
            result = run(invoke, source)
            assert (result.returncode == 0) == allowed, (label, result.returncode, result.stdout, result.stderr)
            assert called.exists() == allowed, label
            assert "Traceback" not in result.stderr and "schema_version" not in result.stdout, label
            passed += 1
            print(f"通过：[UNIT/CONTRACT] {label}", flush=True)

        check("无 TARGET-A 回执时阻止后续发布动作")
        save()
        check("同提交同资产且全部真实验收项通过的回执允许后续动作", True)
        save({**accepted, "schema_version": True})
        check("布尔 true 不能冒充整数 schema_version 1")
        serialized = json.dumps(accepted)
        save_raw(serialized[:-1] + ', "version": "v1.2.1"}')
        check("顶层重复字段即使值相同也被拒绝")
        duplicate_check = '"candidate_installed": true'
        assert duplicate_check in serialized
        save_raw(serialized.replace(duplicate_check, duplicate_check + ', "candidate_installed": true', 1))
        check("嵌套 checks 重复字段即使值相同也被拒绝")
        for field, value in (("commit", "0" * 40), ("archive_sha256", "0" * 64), ("version", "v1.2.0")):
            save({**accepted, field: value})
            check(f"回执 {field} 不匹配时阻止发布")
        for field in sorted(gate.CHECKS):
            save({**accepted, "checks": {**accepted["checks"], field: False}})
            check(f"实机验收项 {field} 未通过时阻止发布")
        for time_value in (None, "invalid", "2020-01-01T00:00:00Z", "2999-01-01T00:00:00Z"):
            save({**accepted, "checked_at": time_value})
            check("无效、过期或未来回执不能证明当前验收")
        save()
        receipt.chmod(0o644)
        check("公开可读回执被拒绝")
        save()
        private_copy = temporary / "private-copy.json"
        shutil.copy2(receipt, private_copy)
        receipt.unlink()
        receipt.symlink_to(private_copy)
        check("符号链接回执被拒绝")
        receipt.unlink()
        os.mkfifo(receipt, 0o600)
        check("FIFO 回执有界拒绝而不是等待输入")
        save()
        archive.write_bytes(original + b"changed")
        check("验收后改包被阻止")
        archive.write_bytes(original)
        checksum.write_text((digest + "  " + archive.name + "\n") * 2, encoding="ascii")
        check("重复校验目标被拒绝")
        checksum.write_text(digest + "  " + archive.name + "\n", encoding="ascii")
        (artifacts / "get.sh").write_text("changed", encoding="utf-8")
        check("get 审计副本与提交不一致被拒绝")
        shutil.copy2(source / "get.sh", artifacts / "get.sh")
        (source / "untracked-file").write_text("uncommitted", encoding="utf-8")
        check("未提交文件存在时阻止发布")
        (source / "untracked-file").unlink()
        (source / "VERSION").write_text("v1.2.1\n\n", encoding="utf-8")
        check("已跟踪源码发生验收后修改时阻止发布")
        print(f"发布门禁专项：{passed} 通过，0 失败；仅机制测试，不是 TARGET-A 验收回执。")


if __name__ == "__main__":
    main()
