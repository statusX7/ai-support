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
identity_spec = importlib.util.spec_from_file_location(
    "release_identity_fixture", ROOT / "tests/test_release_identity.py",
)
identity = importlib.util.module_from_spec(identity_spec)
identity_spec.loader.exec_module(identity)


def run(arguments, cwd, **kwargs):
    return subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, timeout=10, **kwargs)


def main():
    with tempfile.TemporaryDirectory(prefix=".test-runtime.release-gate.", dir=ROOT) as name:
        temporary = Path(name)
        source = identity.create_repository(temporary / "source")
        commit = run(["git", "rev-parse", "HEAD"], source).stdout.strip()
        artifacts = temporary / "artifacts"
        package_result = identity.package(source, artifacts)
        assert package_result.returncode == 0, (
            package_result.returncode, package_result.stdout, package_result.stderr,
        )
        archive = artifacts / "ai-support-v1.3.1.tar.gz"
        original = archive.read_bytes()
        archive.write_bytes(original)
        digest = hashlib.sha256(original).hexdigest()
        checksum = artifacts / "SHA256SUMS"
        assert checksum.read_text(encoding="ascii") == digest + "  " + archive.name + "\n"
        for required in ("scripts/materials-recovery.py", "scripts/atomic-config.py", "config/vision-probe.json"):
            broken = identity.create_repository(
                temporary / ("missing-" + Path(required).stem),
            )
            manifest = broken / gate.MANIFEST_PATH
            lines = [line for line in manifest.read_text(encoding="utf-8").splitlines()
                     if line != required]
            manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
            identity.commit(broken, "fixture missing required helper")
            broken_commit = run(["git", "rev-parse", "HEAD"], broken).stdout.strip()
            try:
                gate.release_manifest(broken, broken_commit, "v1.3.1")
            except ValueError as error:
                assert str(error) == "manifest"
            else:
                raise AssertionError(f"发布门禁接受了缺少 {required} 的清单")
            print(f"通过：[UNIT/CONTRACT] 发布门禁拒绝遗漏 {required}", flush=True)
        receipt = temporary / "receipt.json"
        accepted = {
            "schema_version": 3, "version": "v1.3.1", "commit": commit,
            "archive_sha256": digest, "target_alias": "TARGET-A",
            "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "checks": dict.fromkeys(gate.CHECKS, True),
            "metrics": {
                "eligible_messages_total": 1,
                "eligible_messages_accounted": 1,
                "unexplained_missing": 0,
                "relay_models_total": 3,
                "relay_models_passed": 3,
                "generic_clarifications": 0,
                "duplicate_visible_answers": 0,
            },
        }
        assert {
            "fresh_install_resume", "managed_caddy_fresh_install", "token_input_visible_logs_private",
            "gpt_relay_business_verified", "claude_relay_business_verified", "deepseek_relay_business_verified",
            "crisp_exact_delivery_verified", "affected_regressions_passed", "configuration_data_preserved",
            "production_files_match", "privacy_scan_passed",
        }.issubset(gate.CHECKS)
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
        check("布尔 true 不能冒充整数 schema_version 3")
        save({**accepted, "schema_version": 2})
        check("旧版回执不能冒充本轮增量验收")
        serialized = json.dumps(accepted)
        save_raw(serialized[:-1] + ', "version": "v1.3.1"}')
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
        invalid_metrics = {
            "eligible_messages_total": 0,
            "eligible_messages_accounted": 0,
            "unexplained_missing": 1,
            "relay_models_total": 2,
            "relay_models_passed": 2,
            "generic_clarifications": 1,
            "duplicate_visible_answers": 1,
        }
        for field, value in invalid_metrics.items():
            save({**accepted, "metrics": {**accepted["metrics"], field: value}})
            check(f"实机增量指标 {field} 未达到门槛时阻止发布")
        save({**accepted, "metrics": {**accepted["metrics"], "relay_models_total": True}})
        check("布尔 true 不能冒充数值验收指标")
        now = datetime.datetime.now(datetime.timezone.utc)
        for time_value in (None, "invalid", "2020-01-01T00:00:00Z", "2999-01-01T00:00:00Z",
                           (now - datetime.timedelta(days=8)).isoformat(),
                           (now - datetime.timedelta(hours=1)).isoformat()):
            save({**accepted, "checked_at": time_value})
            check("无效、过期、早于提交或未来回执不能证明当前验收")
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
        (source / "VERSION").write_text("v1.3.1\n\n", encoding="utf-8")
        check("已跟踪源码发生验收后修改时阻止发布")
        run_script = (ROOT / "tests/run.sh").read_text(encoding="utf-8")
        assert "v1.3.1 发布验收不允许 External Validation Pending" in run_script
        print("通过：[UNIT/CONTRACT] v1.3.1 发布测试入口禁止外部验收豁免", flush=True)
        print(f"发布门禁专项：{passed} 通过，0 失败；仅机制测试，不是 TARGET-A 验收回执。")


if __name__ == "__main__":
    main()
