#!/usr/bin/env python3
"""维护者发布门禁：只核对同包实机验收回执，不替代实际测试。"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


CHECKS = {
    "candidate_installed", "production_files_match", "command_menu_doctor",
    "text_knowledge_image_no_rating", "exact_knowledge_answer_verified",
    "welcome_state_verified", "failover_real_upstream",
    "handoff_isolation_cancellation", "restart_new_login", "fixtures_removed_settings_restored",
    "services_running", "privacy_scan_passed", "neutral_display_no_bot_badge",
}


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate")
        value[key] = item
    return value


def safe_file(file, maximum, private=False):
    if any(parent.is_symlink() for parent in (file, *file.parents)):
        raise ValueError("path")
    descriptor = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= maximum:
            raise ValueError("file")
        if private and (info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError("permissions")
        contents = stream.read(maximum + 1)
        if len(contents) > maximum:
            raise ValueError("size")
        return contents


def verify(root, artifacts, receipt):
    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise ValueError("version")
    commit = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True).strip()
    if subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"], stderr=subprocess.DEVNULL):
        raise ValueError("dirty")
    archive_name = "ai-support-" + version + ".tar.gz"
    digest = hashlib.sha256(safe_file(artifacts / archive_name, 256 * 1024 * 1024)).hexdigest()
    checksums = safe_file(artifacts / "SHA256SUMS", 16384).decode("ascii").splitlines()
    if checksums != [digest + "  " + archive_name]:
        raise ValueError("checksum")
    if safe_file(artifacts / "get.sh", 1024 * 1024) != (root / "get.sh").read_bytes():
        raise ValueError("entry")
    record = json.loads(safe_file(receipt, 65536, private=True), object_pairs_hook=unique_object)
    fields = {"schema_version", "version", "commit", "archive_sha256", "target_alias", "checked_at", "checks"}
    if not isinstance(record, dict) or set(record) != fields:
        raise ValueError("receipt")
    if type(record["schema_version"]) is not int or record["schema_version"] != 1 \
            or record["version"] != version or record["commit"] != commit \
            or record["archive_sha256"] != digest or record["target_alias"] != "TARGET-A":
        raise ValueError("identity")
    if not isinstance(record["checked_at"], str):
        raise ValueError("time")
    checked = datetime.datetime.fromisoformat(record["checked_at"].replace("Z", "+00:00"))
    elapsed = (datetime.datetime.now(datetime.timezone.utc) - checked).total_seconds()
    if elapsed < -300 or elapsed > 7 * 86400:
        raise ValueError("age")
    if not isinstance(record["checks"], dict) or set(record["checks"]) != CHECKS or any(value is not True for value in record["checks"].values()):
        raise ValueError("unverified")
    return version


def main():
    parser = argparse.ArgumentParser(description="推送/tag/draft 前核对受限实机验收回执；不联网、不发布、不读取业务秘密。")
    parser.add_argument("--artifacts", required=True, type=Path, help="冻结正式包目录")
    parser.add_argument("--target-receipt", required=True, type=Path, help="唯一远程操作者生成的 0600 脱敏验收回执")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        version = verify(root, args.artifacts.absolute(), args.target_receipt.absolute())
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print("发布已阻止：工作树、冻结包或 TARGET-A 同包验收回执未满足门槛；不得推送、建立远端标签或上传草稿资产。", file=sys.stderr)
        return 1
    print(f"发布前门禁通过：{version} 的受限 TARGET-A 回执与当前提交、完整包一致。仍须按已验证的正式发布流程执行。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
