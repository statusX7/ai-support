#!/usr/bin/env python3
"""维护者发布门禁：只核对同包实机验收回执，不替代实际测试。"""

import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile


CHECKS = {
    "candidate_installed", "production_files_match", "command_menu_doctor",
    "fresh_install_resume", "runner_capacity_preserved",
    "text_knowledge_image_no_rating", "exact_knowledge_answer_verified",
    "welcome_state_verified", "failover_real_upstream",
    "handoff_isolation_cancellation", "restart_new_login", "fixtures_removed_settings_restored",
    "services_running", "privacy_scan_passed", "neutral_display_no_bot_badge",
    "crisp_rest_catchup_verified", "doctor_soft_deleted_backlog_verified",
    "eligible_messages_accounted", "knowledge_case_set_passed",
    "generic_clarification_zero", "catchup_quarantine_budget_verified",
    "observation_15_minutes",
}

METRICS = {
    "eligible_messages_total", "eligible_messages_accounted",
    "unexplained_missing", "knowledge_cases_total", "knowledge_cases_passed",
    "generic_clarifications", "observation_seconds", "duplicate_visible_answers",
}

STRICT_ARCHIVE_VERSION = (1, 2, 2)
AUTHORIZED_RELEASE = "v1.3.0"
MANIFEST_PATH = "scripts/release-manifest.txt"
POLICY_PATH = "config/release-policy.json"
ESSENTIAL_RELEASE_FILES = {
    "VERSION", "get.sh", "install.sh", "manage.sh", "update.sh", "uninstall.sh",
    "docker-compose.yml", "config/app.yaml", POLICY_PATH, "n8n/workflow.json", "n8n/runtime.js",
    "n8n/knowledge-lexical.js", "n8n/build-workflow.js", "scripts/doctor.sh",
    "scripts/package-release.sh", "scripts/visitor-output.js",
    "scripts/materials-recovery.py", "scripts/atomic-config.py",
    "scripts/release-gate.py", MANIFEST_PATH, "scripts/publish-release.sh",
    "tests/run.sh", "tests/test_install_resume.sh", "tests/test_doctor.sh",
    "tests/test_runtime_missing_reply_p0.js", "tests/test_runtime_provider_failure_reply.js",
    "tests/test_release_gate.py", "tests/test_release_identity.py",
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


def git_bytes(root, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(root), *arguments], stderr=subprocess.DEVNULL,
    )


def parsed_version(value):
    match = re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value)
    if not match:
        raise ValueError("version")
    return tuple(int(part) for part in match.groups())


def source_identity(root, requested_commit=None):
    commit = git_bytes(root, "rev-parse", "--verify", "HEAD^{commit}").decode("ascii").strip()
    if requested_commit is not None:
        resolved = git_bytes(root, "rev-parse", "--verify", requested_commit + "^{commit}").decode("ascii").strip()
        if resolved != commit:
            raise ValueError("commit")
    if git_bytes(root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("dirty")
    raw_version = git_bytes(root, "show", commit + ":VERSION")
    try:
        version = raw_version.decode("utf-8").rstrip("\n")
    except UnicodeDecodeError as error:
        raise ValueError("version") from error
    if raw_version != (version + "\n").encode("utf-8"):
        raise ValueError("version")
    parsed_version(version)
    return commit, version


def release_manifest(root, commit, version):
    try:
        raw = git_bytes(root, "show", commit + ":" + MANIFEST_PATH).decode("utf-8")
    except (UnicodeDecodeError, subprocess.SubprocessError) as error:
        raise ValueError("manifest") from error
    paths = []
    seen = set()
    for source_line in raw.splitlines():
        if not source_line or source_line.startswith("#"):
            continue
        path = source_line.replace("@VERSION@", version)
        if (path.startswith("/") or "\\" in path or path != path.strip()
                or any(ord(character) < 32 for character in path)
                or any(part in ("", ".", "..") for part in path.split("/"))
                or "@VERSION@" in path or path in seen):
            raise ValueError("manifest")
        seen.add(path)
        paths.append(path)
    if not paths or not ESSENTIAL_RELEASE_FILES.issubset(seen):
        raise ValueError("manifest")
    return paths


def git_tree_blobs(root, commit, paths):
    records = git_bytes(root, "ls-tree", "-r", "-z", "--full-tree", commit)
    tree = {}
    for record in records.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ")
            path = raw_path.decode("utf-8")
        except (UnicodeDecodeError, ValueError) as error:
            raise ValueError("tree") from error
        tree[path] = (mode, kind, object_id)
    blobs = {}
    for path in paths:
        entry = tree.get(path)
        if entry is None or entry[1] != "blob" or entry[0] not in {"100644", "100755"}:
            raise ValueError("tree")
        blobs[path] = (entry[0], git_bytes(root, "cat-file", "blob", entry[2]))
    return blobs


def verify_version_contract(root, commit, version, blobs):
    try:
        policy = json.loads(blobs[POLICY_PATH][1], object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("release-policy") from error
    expected_policy = {
        "project": "ai-support",
        "authorized_release": AUTHORIZED_RELEASE,
        "allowed_new_release_tags": [AUTHORIZED_RELEASE],
        "allow_auto_version_bump": False,
        "max_new_releases": 1,
        "require_target_a_acceptance": True,
    }
    if policy != expected_policy or version != AUTHORIZED_RELEASE:
        raise ValueError("release-policy")
    expected_get = ('GET_VERSION="' + version + '"').encode("utf-8")
    get_lines = [line for line in blobs["get.sh"][1].splitlines() if line.startswith(b"GET_VERSION=")]
    if get_lines != [expected_get]:
        raise ValueError("get-version")
    app = blobs["config/app.yaml"][1]
    if len(re.findall(rb"(?m)^\s{2}version:\s*" + re.escape(version.encode("utf-8")) + rb"\s*$", app)) != 1:
        raise ValueError("app-version")
    try:
        workflow = json.loads(blobs["n8n/workflow.json"][1], object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("workflow") from error
    metadata = workflow.get("meta") if isinstance(workflow, dict) else None
    runtime = blobs["n8n/runtime.js"][1]
    lexical = blobs.get("n8n/knowledge-lexical.js", (None, b""))[1]
    visitor_output = blobs.get("scripts/visitor-output.js", (None, b""))[1]
    if (not isinstance(metadata, dict) or metadata.get("aiSupportVersion") != version
            or metadata.get("runtimeFileSha256") != hashlib.sha256(runtime).hexdigest()
            or metadata.get("lexicalFileSha256") != hashlib.sha256(lexical).hexdigest()
            or metadata.get("visitorOutputFileSha256") != hashlib.sha256(visitor_output).hexdigest()
            or metadata.get("n8nRunnerConcurrency") != 10
            or metadata.get("backgroundProcessingPermits") != 8
            or metadata.get("ordinaryProcessingPermits") != 7):
        raise ValueError("workflow-identity")
    compose = blobs["docker-compose.yml"][1]
    if b'N8N_RUNNERS_MAX_CONCURRENCY: "10"' not in compose:
        raise ValueError("runner-concurrency")
    for declaration in (
            b"const processingPermitCapacity = 8;",
            b"const ordinaryProcessingPermitCapacity = 7;"):
        if declaration not in runtime:
            raise ValueError("runner-permits")
    result = subprocess.run(
        ["node", str(root / "n8n/build-workflow.js"), "--check"], cwd=root,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False,
    )
    if result.returncode != 0:
        raise ValueError("workflow-generated")


def verify_source(root, requested_commit=None):
    commit, version = source_identity(root, requested_commit)
    paths = release_manifest(root, commit, version)
    blobs = git_tree_blobs(root, commit, paths)
    verify_version_contract(root, commit, version, blobs)
    final_commit, final_version = source_identity(root, commit)
    if final_commit != commit or final_version != version:
        raise ValueError("source-changed")
    return commit, version, paths, blobs


def expected_directories(version, paths):
    root = "ai-support-" + version
    directories = {root}
    for path in paths:
        parts = path.split("/")[:-1]
        for length in range(1, len(parts) + 1):
            directories.add(root + "/" + "/".join(parts[:length]))
    return directories


def verify_archive_matches_source(root, archive, commit, version, paths, blobs):
    contents = safe_file(archive.absolute(), 256 * 1024 * 1024)
    if len(contents) < 10 or contents[:2] != b"\x1f\x8b" or contents[4:8] != b"\0\0\0\0":
        raise ValueError("gzip")
    archive_root = "ai-support-" + version
    expected_files = {archive_root + "/" + path: value for path, value in blobs.items()}
    expected_dirs = expected_directories(version, paths)
    expected_order = sorted(expected_dirs, key=lambda item: (item.count("/"), item)) \
        + sorted(expected_files)
    seen = set()
    member_order = []
    regular = set()
    directories = set()
    expanded = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as source:
            members = source.getmembers()
            if not members or len(members) > 10000:
                raise ValueError("members")
            for member in members:
                name = member.name[:-1] if member.name.endswith("/") else member.name
                if (not name or name in seen or name.startswith("/") or "\\" in name
                        or any(ord(character) < 32 for character in name)
                        or any(part in ("", ".", "..") for part in name.split("/"))
                        or not (name == archive_root or name.startswith(archive_root + "/"))):
                    raise ValueError("archive-path")
                seen.add(name)
                member_order.append(name)
                if member.uid != 0 or member.gid != 0 or member.uname != "root" or member.gname != "root" \
                        or member.mtime != 0 or member.pax_headers:
                    raise ValueError("archive-metadata")
                if member.isdir():
                    if member.mode != 0o755:
                        raise ValueError("directory-mode")
                    directories.add(name)
                    continue
                if not member.isfile() or name not in expected_files:
                    raise ValueError("archive-type")
                mode, expected = expected_files[name]
                if member.mode != (0o755 if mode == "100755" else 0o644):
                    raise ValueError("file-mode")
                if member.size != len(expected):
                    raise ValueError("blob")
                expanded += member.size
                if expanded > 4 * 1024 * 1024 * 1024:
                    raise ValueError("expanded-size")
                stream = source.extractfile(member)
                if stream is None or stream.read(len(expected) + 1) != expected:
                    raise ValueError("blob")
                regular.add(name)
    except (OSError, tarfile.TarError) as error:
        raise ValueError("archive") from error
    if regular != set(expected_files) or directories != expected_dirs \
            or member_order != expected_order:
        raise ValueError("archive-members")
    return hashlib.sha256(contents).hexdigest()


def verify(root, artifacts, receipt):
    commit, version = source_identity(root)
    if version != AUTHORIZED_RELEASE:
        raise ValueError("release-policy")
    archive_name = "ai-support-" + version + ".tar.gz"
    if parsed_version(version) >= STRICT_ARCHIVE_VERSION:
        commit, version, paths, blobs = verify_source(root, commit)
        digest = verify_archive_matches_source(root, artifacts / archive_name, commit, version, paths, blobs)
    else:
        digest = hashlib.sha256(safe_file(artifacts / archive_name, 256 * 1024 * 1024)).hexdigest()
    checksums = safe_file(artifacts / "SHA256SUMS", 16384).decode("ascii").splitlines()
    if checksums != [digest + "  " + archive_name]:
        raise ValueError("checksum")
    if safe_file(artifacts / "get.sh", 1024 * 1024) != git_bytes(root, "show", commit + ":get.sh"):
        raise ValueError("entry")
    record = json.loads(safe_file(receipt, 65536, private=True), object_pairs_hook=unique_object)
    fields = {"schema_version", "version", "commit", "archive_sha256", "target_alias", "checked_at", "checks", "metrics"}
    if not isinstance(record, dict) or set(record) != fields:
        raise ValueError("receipt")
    if type(record["schema_version"]) is not int or record["schema_version"] != 2 \
            or record["version"] != version or record["commit"] != commit \
            or record["archive_sha256"] != digest or record["target_alias"] != "TARGET-A":
        raise ValueError("identity")
    if not isinstance(record["checked_at"], str):
        raise ValueError("time")
    checked = datetime.datetime.fromisoformat(record["checked_at"].replace("Z", "+00:00"))
    if checked.tzinfo is None:
        raise ValueError("time")
    checked = checked.astimezone(datetime.timezone.utc)
    commit_time = datetime.datetime.fromisoformat(
        git_bytes(root, "show", "-s", "--format=%cI", commit).decode("ascii").strip(),
    ).astimezone(datetime.timezone.utc)
    elapsed = (datetime.datetime.now(datetime.timezone.utc) - checked).total_seconds()
    if elapsed < -300 or elapsed > 7 * 86400 or checked < commit_time - datetime.timedelta(seconds=300):
        raise ValueError("age")
    if not isinstance(record["checks"], dict) or set(record["checks"]) != CHECKS or any(value is not True for value in record["checks"].values()):
        raise ValueError("unverified")
    metrics = record["metrics"]
    if not isinstance(metrics, dict) or set(metrics) != METRICS \
            or any(type(value) is not int or value < 0 for value in metrics.values()):
        raise ValueError("metrics")
    if metrics["eligible_messages_total"] < 1 \
            or metrics["eligible_messages_accounted"] != metrics["eligible_messages_total"] \
            or metrics["unexplained_missing"] != 0 \
            or metrics["knowledge_cases_total"] < 12 \
            or metrics["knowledge_cases_passed"] != metrics["knowledge_cases_total"] \
            or metrics["generic_clarifications"] != 0 \
            or metrics["observation_seconds"] < 900 \
            or metrics["duplicate_visible_answers"] != 0:
        raise ValueError("metrics")
    final_commit, final_version = source_identity(root, commit)
    if final_commit != commit or final_version != version:
        raise ValueError("source-changed")
    return version


def main():
    parser = argparse.ArgumentParser(description="推送/tag/draft 前核对受限实机验收回执；不联网、不发布、不读取业务秘密。")
    parser.add_argument("--artifacts", type=Path, help="冻结正式包目录")
    parser.add_argument("--target-receipt", type=Path, help="唯一远程操作者生成的 0600 脱敏验收回执")
    parser.add_argument("--verify-source", action="store_true", help="仅核对当前干净 HEAD 的清单、版本和工作流生成一致性")
    parser.add_argument("--verify-archive", type=Path, help="仅核对规范归档与当前干净 HEAD 逐成员一致")
    parser.add_argument("--commit", help="与当前 HEAD 完全一致的固定提交")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        if args.verify_source or args.verify_archive is not None:
            if args.artifacts is not None or args.target_receipt is not None or not args.commit \
                    or args.verify_source == (args.verify_archive is not None):
                raise ValueError("arguments")
            commit, version, paths, blobs = verify_source(root, args.commit)
            if args.verify_archive is not None:
                verify_archive_matches_source(root, args.verify_archive, commit, version, paths, blobs)
            print(f"源码身份核对通过：{version} 的固定清单、版本和工作流与提交 {commit[:12]} 一致。")
            return 0
        if args.artifacts is None or args.target_receipt is None or args.commit is not None:
            raise ValueError("arguments")
        version = verify(root, args.artifacts.absolute(), args.target_receipt.absolute())
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print("发布已阻止：工作树、冻结包或 TARGET-A 同包验收回执未满足门槛；不得推送、建立远端标签或上传草稿资产。", file=sys.stderr)
        return 1
    print(f"发布前门禁通过：{version} 的受限 TARGET-A 回执与当前提交、完整包一致。仍须按已验证的正式发布流程执行。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
