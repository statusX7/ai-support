#!/usr/bin/env python3
"""发布身份专项：只在临时 Git 中构建、篡改和 dry-run，不访问网络。"""

import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
VERSION = "v1.3.0"


def run(arguments, cwd, *, environment=None, timeout=90):
    return subprocess.run(
        [str(item) for item in arguments], cwd=cwd, env=environment,
        capture_output=True, text=True, timeout=timeout, check=False,
    )


def require_success(result, label):
    assert result.returncode == 0, (label, result.returncode, result.stdout, result.stderr)


def manifest_paths(contents):
    paths = []
    for line in contents.splitlines():
        if not line or line.startswith("#"):
            continue
        paths.append(line.replace("@VERSION@", VERSION))
    return paths


def build_script():
    return r'''#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = path.resolve(__dirname, '..');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();
const runtime = fs.readFileSync(path.join(__dirname, 'runtime.js'));
const lexical = fs.readFileSync(path.join(__dirname, 'knowledge-lexical.js'));
const visitorOutput = fs.readFileSync(path.join(root, 'scripts', 'visitor-output.js'));
const workflow = {meta:{
  aiSupportVersion: version,
  runtimeFileSha256: crypto.createHash('sha256').update(runtime).digest('hex'),
  lexicalFileSha256: crypto.createHash('sha256').update(lexical).digest('hex'),
  visitorOutputFileSha256: crypto.createHash('sha256').update(visitorOutput).digest('hex'),
  n8nRunnerConcurrency: 10,
  backgroundProcessingPermits: 8,
  ordinaryProcessingPermits: 7
}};
const rendered = JSON.stringify(workflow, null, 2) + '\n';
const target = path.join(__dirname, 'workflow.json');
if (process.argv.includes('--check')) {
  if (fs.readFileSync(target, 'utf8') !== rendered) process.exitCode = 1;
} else {
  fs.writeFileSync(target, rendered);
}
'''


def create_repository(destination):
    destination.mkdir()
    manifest = (ROOT / "scripts/release-manifest.txt").read_text(encoding="utf-8")
    for relative in manifest_paths(manifest):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"fixture: {relative}\n", encoding="utf-8")

    for relative in (
        "scripts/package-release.sh", "scripts/release-gate.py",
        "scripts/publish-release.sh", "scripts/release-manifest.txt",
    ):
        shutil.copy2(ROOT / relative, destination / relative)

    (destination / ".gitignore").write_text(
        ".release-package.*\ndist/\n", encoding="utf-8",
    )
    (destination / "VERSION").write_text(VERSION + "\n", encoding="utf-8")
    (destination / "get.sh").write_text(
        '#!/usr/bin/env bash\nGET_VERSION="v1.3.0"\n', encoding="utf-8",
    )
    (destination / "config/app.yaml").write_text(
        "app:\n  version: v1.3.0\n", encoding="utf-8",
    )
    (destination / "config/release-policy.json").write_text(
        json.dumps({
            "project": "ai-support",
            "authorized_release": VERSION,
            "allowed_new_release_tags": [VERSION],
            "allow_auto_version_bump": False,
            "max_new_releases": 1,
            "require_target_a_acceptance": True,
        }, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (destination / "docker-compose.yml").write_text(
        'services:\n  n8n:\n    environment:\n      N8N_RUNNERS_MAX_CONCURRENCY: "10"\n',
        encoding="utf-8",
    )
    (destination / "n8n/runtime.js").write_text(
        "const processingPermitCapacity = 8;\n"
        "const ordinaryProcessingPermitCapacity = 7;\n",
        encoding="utf-8",
    )
    (destination / "n8n/knowledge-lexical.js").write_text(
        "module.exports = {};\n", encoding="utf-8",
    )
    (destination / "n8n/build-workflow.js").write_text(
        build_script(), encoding="utf-8",
    )
    require_success(run(["node", "n8n/build-workflow.js"], destination), "生成合成工作流")

    executable = {
        "get.sh", "install.sh", "manage.sh", "update.sh", "uninstall.sh",
        "scripts/package-release.sh", "scripts/publish-release.sh",
        "n8n/build-workflow.js",
    }
    for relative in executable:
        (destination / relative).chmod(0o755)

    commands = (
        ["git", "init", "--quiet"],
        ["git", "symbolic-ref", "HEAD", "refs/heads/main"],
        ["git", "add", "."],
        ["git", "-c", "user.name=Release Identity Test",
         "-c", "user.email=release@example.invalid", "commit", "--quiet",
         "-m", "fixture"],
    )
    for command in commands:
        require_success(run(command, destination), "初始化临时 Git")
    return destination


def clone_repository(source, destination):
    require_success(
        run(["git", "clone", "--quiet", "--no-hardlinks", source, destination], source.parent),
        "复制临时 Git",
    )
    return destination


def commit(repository, message):
    require_success(run(["git", "add", "-A"], repository), "暂存临时负例")
    require_success(run([
        "git", "-c", "user.name=Release Identity Test",
        "-c", "user.email=release@example.invalid", "commit", "--quiet", "-m", message,
    ], repository), "提交临时负例")


def package(repository, output):
    return run([
        repository / "scripts/package-release.sh", "--output-dir", output,
    ], repository)


def rewrite_archive(source, destination, *, target, replacement=None, mode=None, reverse=False):
    with tarfile.open(source, mode="r:gz") as archive:
        records = []
        for member in archive.getmembers():
            payload = archive.extractfile(member).read() if member.isfile() else None
            records.append((member, payload))
    if reverse:
        records.reverse()
    with destination.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.GNU_FORMAT) as archive:
                for original, payload in records:
                    member = tarfile.TarInfo(original.name)
                    member.type = original.type
                    member.mode = original.mode
                    member.uid = member.gid = 0
                    member.uname = member.gname = "root"
                    member.mtime = 0
                    if original.name.endswith("/" + target):
                        if replacement is not None:
                            payload = replacement
                        if mode is not None:
                            member.mode = mode
                    if original.isfile():
                        member.size = len(payload)
                        archive.addfile(member, io.BytesIO(payload))
                    else:
                        archive.addfile(member)


def write_receipt(path, repository, archive, checks, *, valid=True):
    commit_id = run(["git", "rev-parse", "HEAD"], repository).stdout.strip()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    record = {
        "schema_version": 2,
        "version": VERSION,
        "commit": commit_id,
        "archive_sha256": digest,
        "target_alias": "TARGET-A",
        "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "checks": dict.fromkeys(checks, True),
        "metrics": {
            "eligible_messages_total": 1,
            "eligible_messages_accounted": 1,
            "unexplained_missing": 0,
            "knowledge_cases_total": 12,
            "knowledge_cases_passed": 12,
            "generic_clarifications": 0,
            "observation_seconds": 900,
            "duplicate_visible_answers": 0,
        },
    }
    if not valid:
        record["archive_sha256"] = "0" * 64
    path.write_text(json.dumps(record), encoding="utf-8")
    path.chmod(0o600)


def fake_publish_tools(directory):
    directory.mkdir()
    real_git = shutil.which("git")
    assert real_git
    git = directory / "git"
    git.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
for argument in "${arguments[@]}"; do
  if [[ "$argument" == push && -n "${FAKE_GIT_FAIL_PUSH_ONCE:-}" ]]; then
    marker=${FAKE_GIT_FAIL_PUSH_ONCE}
    if [[ ! -e "$marker" ]]; then
      printf '%s\n' 'failed once' > "$marker"
      exit 99
    fi
    break
  fi
done
for (( index=0; index+1<${#arguments[@]}; index++ )); do
  if [[ "${arguments[index]}" == remote && "${arguments[index+1]}" == get-url ]]; then
    printf '%s\n' 'https://github.com/statusX7/ai-support.git'
    exit 0
  fi
done
exec "${REAL_GIT:?}" "$@"
''', encoding="utf-8")
    git.chmod(0o755)
    gh = directory / "gh"
    gh.write_text(r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

arguments = sys.argv[1:]
state_path = Path(os.environ["FAKE_GH_STATE"])
assets = Path(os.environ["FAKE_GH_ASSETS"])
assets.mkdir(parents=True, exist_ok=True)
with Path(os.environ["FAKE_GH_LOG"]).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(arguments) + "\n")

def state():
    return json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else None

def save(value):
    state_path.write_text(json.dumps(value), encoding="utf-8")

def fail_once(variable):
    value = os.environ.get(variable)
    if not value:
        return False
    marker = Path(value)
    if marker.exists():
        return False
    marker.write_text("failed once\n", encoding="utf-8")
    return True

if arguments[:2] == ["auth", "status"]:
    raise SystemExit(0)
if arguments[:2] == ["repo", "view"]:
    print("statusX7/ai-support false")
    raise SystemExit(0)
if arguments and arguments[0] == "api":
    endpoint = next((item for item in arguments[1:] if not item.startswith("-")), "")
    current = state()
    if endpoint.endswith("/releases/latest"):
        if not current or current["draft"]:
            raise SystemExit(1)
        print(current["version"])
        raise SystemExit(0)
    if "/releases/tags/" in endpoint:
        if os.environ.get("FAKE_GH_API_ERROR") == "1":
            print("HTTP/2 403 Forbidden\n\n{}")
            raise SystemExit(1)
        if current:
            print("HTTP/2 200 OK\n\n{}")
            raise SystemExit(0)
        print("HTTP/2 404 Not Found\n\n{}")
        raise SystemExit(1)
    raise SystemExit(1)
if arguments[:2] == ["release", "view"]:
    current = state()
    if not current:
        raise SystemExit(1)
    print(json.dumps({
        "tagName": current["version"], "isDraft": current["draft"],
        "isPrerelease": current["prerelease"],
        "assets": [{"name": item.name} for item in sorted(assets.iterdir()) if item.is_file()],
    }))
    raise SystemExit(0)
if arguments[:2] == ["release", "create"]:
    if fail_once("FAKE_GH_FAIL_CREATE_ONCE"):
        raise SystemExit(99)
    version = arguments[2]
    for item in arguments[3:]:
        if item.startswith("--"):
            break
        source = Path(item)
        shutil.copy2(source, assets / source.name)
    save({"version": version, "draft": True, "prerelease": False})
    raise SystemExit(0)
if arguments[:2] == ["release", "upload"]:
    current = state()
    if not current:
        raise SystemExit(1)
    clobber = "--clobber" in arguments
    for item in arguments[3:]:
        if item.startswith("--"):
            break
        source = Path(item)
        destination = assets / source.name
        if destination.exists() and not clobber:
            raise SystemExit(1)
        shutil.copy2(source, destination)
    raise SystemExit(0)
if arguments[:2] == ["release", "download"]:
    if fail_once("FAKE_GH_FAIL_DOWNLOAD_ONCE"):
        raise SystemExit(99)
    destination = Path(arguments[arguments.index("--dir") + 1])
    for source in assets.iterdir():
        if source.is_file():
            shutil.copy2(source, destination / source.name)
    raise SystemExit(0)
if arguments[:2] == ["release", "edit"]:
    current = state()
    if not current:
        raise SystemExit(1)
    if "--draft=false" in arguments:
        current["draft"] = False
    if "--prerelease=false" in arguments:
        current["prerelease"] = False
    save(current)
    raise SystemExit(0)
raise SystemExit(98)
''', encoding="utf-8")
    gh.chmod(0o755)
    return real_git


def formal_fixture(base, temporary, name, checks):
    repository = clone_repository(base, temporary / (name + "-source"))
    remote = temporary / (name + "-remote.git")
    require_success(run(["git", "init", "--quiet", "--bare", remote], temporary), "创建发布远端夹具")
    require_success(run(["git", "remote", "remove", "origin"], repository), "移除默认远端")
    require_success(run(["git", "remote", "add", "origin", remote], repository), "登记发布远端夹具")
    artifacts = temporary / (name + "-artifacts")
    require_success(package(repository, artifacts), "构建正式流程夹具")
    archive = artifacts / f"ai-support-{VERSION}.tar.gz"
    receipt = temporary / (name + "-receipt.json")
    write_receipt(receipt, repository, archive, checks)
    fake_bin = temporary / (name + "-bin")
    real_git = fake_publish_tools(fake_bin)
    environment = os.environ.copy()
    environment.update({
        "PATH": str(fake_bin) + os.pathsep + environment["PATH"],
        "REAL_GIT": real_git,
        "GIT_AUTHOR_NAME": "Release Identity Test",
        "GIT_AUTHOR_EMAIL": "release@example.invalid",
        "GIT_COMMITTER_NAME": "Release Identity Test",
        "GIT_COMMITTER_EMAIL": "release@example.invalid",
        "FAKE_GH_STATE": str(temporary / (name + "-gh-state.json")),
        "FAKE_GH_ASSETS": str(temporary / (name + "-gh-assets")),
        "FAKE_GH_LOG": str(temporary / (name + "-gh.log")),
    })
    return repository, remote, artifacts, receipt, environment


def write_verification(path, repository, archive, *, body):
    commit_id = run(["git", "rev-parse", "HEAD"], repository).stdout.strip()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    metadata = {
        "schema_version": 1,
        "version": VERSION,
        "commit": commit_id,
        "archive_sha256": digest,
        "release_url": f"https://github.com/statusX7/ai-support/releases/tag/{VERSION}",
    }
    path.write_text(
        "<!-- crispai-verification: " + json.dumps(metadata, separators=(",", ":")) + " -->\n"
        + body.rstrip("\n") + "\n",
        encoding="utf-8",
    )
    path.chmod(0o600)


def expect_package_failure(base, temporary, name, mutate):
    repository = clone_repository(base, temporary / ("case-" + name))
    mutate(repository)
    commit(repository, name)
    result = package(repository, temporary / ("out-" + name))
    assert result.returncode != 0, (name, result.stdout, result.stderr)
    assert "Traceback" not in result.stderr, name
    print(f"通过：[UNIT/CONTRACT] {name}", flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix="crispai-release-identity-") as name:
        temporary = Path(name)
        base = create_repository(temporary / "source")
        artifacts_one = temporary / "artifacts-one"
        artifacts_two = temporary / "artifacts-two"
        result = package(base, artifacts_one)
        require_success(result, "从固定 HEAD 构建正式包")
        result = package(base, artifacts_two)
        require_success(result, "重复构建正式包")
        archive_one = artifacts_one / f"ai-support-{VERSION}.tar.gz"
        archive_two = artifacts_two / f"ai-support-{VERSION}.tar.gz"
        assert archive_one.read_bytes() == archive_two.read_bytes()
        print("通过：[UNIT/CONTRACT] 两次固定 Git tree 构建逐字一致", flush=True)

        commit_id = run(["git", "rev-parse", "HEAD"], base).stdout.strip()
        gate_cli = base / "scripts/release-gate.py"
        require_success(run([
            "python3", gate_cli, "--verify-source", "--commit", commit_id,
        ], base), "固定源码身份")
        require_success(run([
            "python3", gate_cli, "--verify-archive", archive_one,
            "--commit", commit_id,
        ], base), "归档逐成员身份")
        print("通过：[UNIT/CONTRACT] 版本、工作流、清单和归档成员与 HEAD 一致", flush=True)

        namespace = runpy.run_path(str(gate_cli))
        _, _, paths, blobs = namespace["verify_source"](base, commit_id)
        corrupted = temporary / "corrupted.tar.gz"
        rewrite_archive(archive_one, corrupted, target="install.sh", replacement=b"changed\n")
        try:
            namespace["verify_archive_matches_source"](
                base, corrupted, commit_id, VERSION, paths, blobs,
            )
        except ValueError as error:
            assert str(error) == "blob", error
        else:
            raise AssertionError("篡改 HEAD blob 后仍通过")
        print("通过：[UNIT/CONTRACT] 包成员内容偏离 HEAD blob 被拒绝", flush=True)

        wrong_mode = temporary / "wrong-mode.tar.gz"
        rewrite_archive(archive_one, wrong_mode, target="install.sh", mode=0o644)
        try:
            namespace["verify_archive_matches_source"](
                base, wrong_mode, commit_id, VERSION, paths, blobs,
            )
        except ValueError as error:
            assert str(error) == "file-mode", error
        else:
            raise AssertionError("篡改执行位后仍通过")
        print("通过：[UNIT/CONTRACT] 包成员执行位偏离 Git tree 被拒绝", flush=True)

        reordered = temporary / "reordered.tar.gz"
        rewrite_archive(archive_one, reordered, target="unused", reverse=True)
        try:
            namespace["verify_archive_matches_source"](
                base, reordered, commit_id, VERSION, paths, blobs,
            )
        except ValueError as error:
            assert str(error) == "archive-members", error
        else:
            raise AssertionError("非规范成员顺序仍通过")
        print("通过：[UNIT/CONTRACT] 非规范归档成员顺序被拒绝", flush=True)

        manifest_original = (base / "scripts/release-manifest.txt").read_text(encoding="utf-8")

        def remove_manifest(repository):
            (repository / "scripts/release-manifest.txt").unlink()

        def duplicate_manifest(repository):
            path = repository / "scripts/release-manifest.txt"
            path.write_text(manifest_original + "VERSION\n", encoding="utf-8")

        def unsafe_manifest(repository):
            path = repository / "scripts/release-manifest.txt"
            path.write_text(manifest_original + "../outside\n", encoding="utf-8")

        def omit_essential(repository):
            path = repository / "scripts/release-manifest.txt"
            lines = [line for line in manifest_original.splitlines() if line != "install.sh"]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        def omit_provider_failure_reply(repository):
            path = repository / "scripts/release-manifest.txt"
            lines = [line for line in manifest_original.splitlines()
                     if line != "tests/test_runtime_provider_failure_reply.js"]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        def omit_doctor_contract(repository):
            path = repository / "scripts/release-manifest.txt"
            lines = [line for line in manifest_original.splitlines()
                     if line != "tests/test_doctor.sh"]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        def omit_materials_recovery(repository):
            path = repository / "scripts/release-manifest.txt"
            lines = [line for line in manifest_original.splitlines()
                     if line != "scripts/materials-recovery.py"]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        def omit_atomic_config(repository):
            path = repository / "scripts/release-manifest.txt"
            lines = [line for line in manifest_original.splitlines()
                     if line != "scripts/atomic-config.py"]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        def missing_tree_blob(repository):
            path = repository / "scripts/release-manifest.txt"
            path.write_text(manifest_original + "not-tracked.txt\n", encoding="utf-8")

        def version_drift(repository):
            (repository / "get.sh").write_text(
                '#!/usr/bin/env bash\nGET_VERSION="v9.9.9"\n', encoding="utf-8",
            )

        def release_policy_drift(repository):
            policy = repository / "config/release-policy.json"
            record = json.loads(policy.read_text(encoding="utf-8"))
            record["authorized_release"] = "v1.3.1"
            record["allowed_new_release_tags"] = ["v1.3.1"]
            policy.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

        def generated_workflow_drift(repository):
            path = repository / "n8n/workflow.json"
            path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")

        def visitor_output_identity_drift(repository):
            builder = repository / "n8n/build-workflow.js"
            source = builder.read_text(encoding="utf-8")
            expected = "visitorOutputFileSha256: crypto.createHash('sha256').update(visitorOutput).digest('hex'),"
            assert expected in source
            builder.write_text(source.replace(
                expected, "visitorOutputFileSha256: '0'.repeat(64),", 1,
            ), encoding="utf-8")
            require_success(run(["node", "n8n/build-workflow.js"], repository),
                            "生成错误访客输出身份夹具")

        for case_name, mutator in (
            ("固定清单文件缺失时拒绝打包", remove_manifest),
            ("固定清单重复路径时拒绝打包", duplicate_manifest),
            ("固定清单不安全路径时拒绝打包", unsafe_manifest),
            ("固定清单遗漏自举成员时拒绝打包", omit_essential),
            ("固定清单遗漏访客全池失败回归时拒绝打包", omit_provider_failure_reply),
            ("固定清单遗漏补偿与软删除自检回归时拒绝打包", omit_doctor_contract),
            ("固定清单遗漏资料恢复事务模块时拒绝打包", omit_materials_recovery),
            ("固定清单遗漏敏感配置原子提交模块时拒绝打包", omit_atomic_config),
            ("固定清单引用非 HEAD blob 时拒绝打包", missing_tree_blob),
            ("版本投影与 VERSION 不一致时拒绝打包", version_drift),
            ("版本政策改变为未授权版本时拒绝打包", release_policy_drift),
            ("工作流生成结果不一致时拒绝打包", generated_workflow_drift),
            ("生成器与工作流共同伪报访客输出哈希时拒绝打包", visitor_output_identity_drift),
        ):
            expect_package_failure(base, temporary, case_name, mutator)

        (base / "untracked-dirty").write_text("dirty\n", encoding="utf-8")
        dirty = package(base, temporary / "dirty-output")
        assert dirty.returncode != 0 and "未跟踪" in dirty.stderr
        (base / "untracked-dirty").unlink()
        print("通过：[UNIT/CONTRACT] 任意未跟踪脏项阻止正式打包", flush=True)

        tracked_path = base / "README.md"
        tracked_original = tracked_path.read_bytes()
        tracked_path.write_bytes(tracked_original + b"working tree drift\n")
        tracked_dirty = package(base, temporary / "tracked-dirty-output")
        assert tracked_dirty.returncode != 0 and "已修改" in tracked_dirty.stderr
        tracked_path.write_bytes(tracked_original)
        assert run(["git", "status", "--porcelain"], base).stdout == ""
        print("通过：[UNIT/CONTRACT] 任意已跟踪未暂存脏项阻止正式打包", flush=True)

        tracked_path.write_bytes(tracked_original + b"index drift\n")
        require_success(run(["git", "add", "README.md"], base), "暂存负例")
        staged_dirty = package(base, temporary / "staged-dirty-output")
        assert staged_dirty.returncode != 0 and "已暂存" in staged_dirty.stderr
        tracked_path.write_bytes(tracked_original)
        require_success(run(["git", "add", "README.md"], base), "恢复暂存负例")
        assert run(["git", "status", "--porcelain"], base).stdout == ""
        print("通过：[UNIT/CONTRACT] 任意已暂存脏项阻止正式打包", flush=True)

        output_parent = temporary / "output-parent"
        output_parent.mkdir()
        output_link = temporary / "output-link"
        output_link.symlink_to(output_parent, target_is_directory=True)
        linked_output = package(base, output_link / "dist")
        assert linked_output.returncode != 0 and not (output_parent / "dist").exists()
        assert "符号链接" in linked_output.stderr
        print("通过：[UNIT/CONTRACT] 打包输出目录的符号链接父路径在写入前被拒绝", flush=True)

        checks = namespace["CHECKS"]
        receipt = temporary / "receipt.json"
        write_receipt(receipt, base, archive_one, checks)
        fake_bin = temporary / "fake-bin"
        fake_bin.mkdir()
        gh_marker = temporary / "gh-called"
        fake_gh = fake_bin / "gh"
        fake_gh.write_text(
            '#!/usr/bin/env bash\nprintf called > "${GH_MARKER:?}"\nexit 99\n',
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        environment["GH_MARKER"] = str(gh_marker)
        publish = base / "scripts/publish-release.sh"
        wrong_version = run([
            publish, "--publish", "v1.3.1", "--artifacts", artifacts_one,
            "--target-receipt", receipt, "--dry-run",
        ], base, environment=environment)
        assert wrong_version.returncode == 64
        assert "只授权 v1.3.0" in wrong_version.stderr
        assert not gh_marker.exists()
        assert run(["git", "tag", "--list"], base).stdout == ""
        print("通过：[UNIT/CONTRACT] 非 v1.3.0 参数在 tag/push/draft 前被拒绝", flush=True)

        dry_run = run([
            publish, "--publish", VERSION, "--artifacts", artifacts_one,
            "--target-receipt", receipt, "--dry-run",
        ], base, environment=environment)
        require_success(dry_run, "正式发布 dry-run")
        assert "未创建 tag、未连接 GitHub" in dry_run.stdout
        assert not gh_marker.exists()
        assert run(["git", "tag", "--list"], base).stdout == ""
        print("通过：[UNIT/CONTRACT] dry-run 通过门禁但不访问 GitHub 或创建 tag", flush=True)

        receipt_link = temporary / "receipt-link.json"
        receipt_link.symlink_to(receipt)
        linked_receipt = run([
            publish, "--publish", VERSION, "--artifacts", artifacts_one,
            "--target-receipt", receipt_link, "--dry-run",
        ], base, environment=environment)
        assert linked_receipt.returncode != 0 and not gh_marker.exists()
        receipt_link.unlink()
        artifacts_link = temporary / "artifacts-link"
        artifacts_link.symlink_to(artifacts_one, target_is_directory=True)
        linked_artifacts = run([
            publish, "--publish", VERSION, "--artifacts", artifacts_link,
            "--target-receipt", receipt, "--dry-run",
        ], base, environment=environment)
        assert linked_artifacts.returncode != 0 and not gh_marker.exists()
        artifacts_link.unlink()
        print("通过：[UNIT/CONTRACT] 发布入口拒绝回执或资产路径中的符号链接", flush=True)

        missing_publish = run([
            publish, "--artifacts", artifacts_one, "--target-receipt", receipt,
        ], base, environment=environment)
        assert missing_publish.returncode == 64 and not gh_marker.exists()
        print("通过：[UNIT/CONTRACT] 未显式 --publish 时发布入口拒绝执行", flush=True)

        write_receipt(receipt, base, archive_one, checks, valid=False)
        blocked_formal = run([
            publish, "--publish", VERSION, "--artifacts", artifacts_one,
            "--target-receipt", receipt,
        ], base, environment=environment)
        assert blocked_formal.returncode != 0 and not gh_marker.exists()
        assert run(["git", "tag", "--list"], base).stdout == ""
        print("通过：[UNIT/CONTRACT] 回执失败发生在 tag、push 和 draft 之前", flush=True)

        checks = namespace["CHECKS"]
        push_repo, push_remote, push_artifacts, push_receipt, push_env = formal_fixture(
            base, temporary, "retry-after-push-failure", checks,
        )
        push_marker = temporary / "push-failed-once"
        push_env["FAKE_GIT_FAIL_PUSH_ONCE"] = str(push_marker)
        push_publish = push_repo / "scripts/publish-release.sh"
        push_arguments = [
            push_publish, "--publish", VERSION, "--artifacts", push_artifacts,
            "--target-receipt", push_receipt,
        ]
        push_first = run(push_arguments, push_repo, environment=push_env)
        assert push_first.returncode != 0 and push_marker.exists(), (
            push_first.returncode, push_first.stdout, push_first.stderr,
        )
        assert run(["git", "cat-file", "-t", f"refs/tags/{VERSION}"], push_repo).stdout.strip() == "tag"
        assert run(["git", "ls-remote", "--tags", push_remote], push_repo).stdout == ""
        assert not Path(push_env["FAKE_GH_STATE"]).exists()
        push_retry = run(push_arguments, push_repo, environment=push_env)
        require_success(push_retry, "本地 tag 创建后原子推送失败的同版本重试")
        assert json.loads(Path(push_env["FAKE_GH_STATE"]).read_text(encoding="utf-8"))["draft"] is False
        print("通过：[UNIT/CONTRACT] 本地 tag 创建后推送失败可由同一冻结命令安全续发", flush=True)

        retry_repo, retry_remote, retry_artifacts, retry_receipt, retry_env = formal_fixture(
            base, temporary, "retry-after-tag", checks,
        )
        retry_marker = temporary / "retry-create-once"
        retry_env["FAKE_GH_FAIL_CREATE_ONCE"] = str(retry_marker)
        retry_publish = retry_repo / "scripts/publish-release.sh"
        retry_arguments = [
            retry_publish, "--publish", VERSION, "--artifacts", retry_artifacts,
            "--target-receipt", retry_receipt,
        ]
        first_publish = run(retry_arguments, retry_repo, environment=retry_env)
        assert first_publish.returncode != 0 and retry_marker.exists()
        assert run(["git", "cat-file", "-t", f"refs/tags/{VERSION}"], retry_repo).stdout.strip() == "tag"
        source_commit = run(["git", "rev-parse", "HEAD"], retry_repo).stdout.strip()
        remote_peeled = run([
            "git", "ls-remote", retry_remote, f"refs/tags/{VERSION}^{{}}",
        ], retry_repo).stdout.split()[0]
        assert remote_peeled == source_commit
        second_publish = run(retry_arguments, retry_repo, environment=retry_env)
        require_success(second_publish, "本地/远端 tag 留存后的同版本重试")
        retry_state = json.loads(Path(retry_env["FAKE_GH_STATE"]).read_text(encoding="utf-8"))
        assert retry_state == {"version": VERSION, "draft": False, "prerelease": False}
        print("通过：[UNIT/CONTRACT] tag 已推送但 draft 创建失败后同一命令安全续发", flush=True)

        third_publish = run(retry_arguments, retry_repo, environment=retry_env)
        require_success(third_publish, "正式发布完成后的幂等复核")
        retry_log = [json.loads(line) for line in Path(retry_env["FAKE_GH_LOG"]).read_text(encoding="utf-8").splitlines()]
        assert sum(entry[:2] == ["release", "create"] for entry in retry_log) == 2
        assert sum(entry[:2] == ["release", "edit"] and "--draft=false" in entry for entry in retry_log) == 1
        print("通过：[UNIT/CONTRACT] 已正式发布的同版本重跑只复核，不重建或重发 Release", flush=True)

        draft_repo, _, draft_artifacts, draft_receipt, draft_env = formal_fixture(
            base, temporary, "resume-draft", checks,
        )
        download_marker = temporary / "draft-download-once"
        draft_env["FAKE_GH_FAIL_DOWNLOAD_ONCE"] = str(download_marker)
        draft_publish = draft_repo / "scripts/publish-release.sh"
        draft_arguments = [
            draft_publish, "--publish", VERSION, "--artifacts", draft_artifacts,
            "--target-receipt", draft_receipt,
        ]
        draft_first = run(draft_arguments, draft_repo, environment=draft_env)
        assert draft_first.returncode != 0 and download_marker.exists()
        draft_state_path = Path(draft_env["FAKE_GH_STATE"])
        assert json.loads(draft_state_path.read_text(encoding="utf-8"))["draft"] is True
        draft_assets = Path(draft_env["FAKE_GH_ASSETS"])
        (draft_assets / "unexpected.bin").write_bytes(b"must not be deleted")
        extra_blocked = run(draft_arguments, draft_repo, environment=draft_env)
        assert extra_blocked.returncode != 0 and (draft_assets / "unexpected.bin").read_bytes() == b"must not be deleted"
        assert json.loads(draft_state_path.read_text(encoding="utf-8"))["draft"] is True
        (draft_assets / "unexpected.bin").unlink()
        (draft_assets / f"ai-support-{VERSION}.tar.gz").write_bytes(b"corrupted draft asset")
        (draft_assets / "get.sh").unlink()
        draft_retry = run(draft_arguments, draft_repo, environment=draft_env)
        require_success(draft_retry, "部分/错误 draft 资产的受控恢复")
        assert (draft_assets / f"ai-support-{VERSION}.tar.gz").read_bytes() \
            == (draft_artifacts / f"ai-support-{VERSION}.tar.gz").read_bytes()
        assert (draft_assets / "get.sh").read_bytes() == (draft_artifacts / "get.sh").read_bytes()
        assert json.loads(draft_state_path.read_text(encoding="utf-8"))["draft"] is False
        print("通过：[UNIT/CONTRACT] draft 多余资产被阻止，缺失或错误的预期资产可由同包安全恢复", flush=True)

        (draft_assets / f"ai-support-{VERSION}.tar.gz").write_bytes(b"published asset changed")
        published_tamper = run(draft_arguments, draft_repo, environment=draft_env)
        assert published_tamper.returncode != 0
        assert json.loads(draft_state_path.read_text(encoding="utf-8"))["draft"] is False
        print("通过：[UNIT/CONTRACT] 已发布资产被改动时重跑拒绝冒充同一冻结包", flush=True)

        verification_repo, _, verification_artifacts, verification_receipt, verification_env = formal_fixture(
            base, temporary, "published-verification", checks,
        )
        verification_publish = verification_repo / "scripts/publish-release.sh"
        verification_arguments = [
            verification_publish, "--publish", VERSION, "--artifacts", verification_artifacts,
            "--target-receipt", verification_receipt,
        ]
        verification_file = temporary / f"{VERSION}-verification.md"
        write_verification(
            verification_file, verification_repo,
            verification_artifacts / f"ai-support-{VERSION}.tar.gz",
            body="公开下载、Latest 与匿名安装结果已核对，未包含受限现场信息。",
        )
        unpublished_verification = run(
            verification_arguments + ["--verification", verification_file],
            verification_repo, environment=verification_env,
        )
        assert unpublished_verification.returncode != 0
        assert run(["git", "tag", "--list"], verification_repo).stdout == ""
        assert not Path(verification_env["FAKE_GH_STATE"]).exists()
        print("通过：[UNIT/CONTRACT] 验证附件不能用于 draft 或首次正式发布", flush=True)
        require_success(
            run(verification_arguments, verification_repo, environment=verification_env),
            "建立仅含三项核心资产的已发布夹具",
        )
        dry_verification = run(
            verification_arguments + ["--verification", verification_file, "--dry-run"],
            verification_repo, environment=verification_env,
        )
        assert dry_verification.returncode != 0
        write_verification(
            verification_file, verification_repo,
            verification_artifacts / f"ai-support-{VERSION}.tar.gz",
            body="公开结论提及 TARGET-A，因包含目标别名必须拒绝上传。",
        )
        target_identifier = run(
            verification_arguments + ["--verification", verification_file],
            verification_repo, environment=verification_env,
        )
        assert target_identifier.returncode != 0
        verification_assets = Path(verification_env["FAKE_GH_ASSETS"])
        assert {item.name for item in verification_assets.iterdir()} == {
            f"ai-support-{VERSION}.tar.gz", "SHA256SUMS", "get.sh",
        }
        write_verification(
            verification_file, verification_repo,
            verification_artifacts / f"ai-support-{VERSION}.tar.gz",
            body="Authorization: synthetic-test-value",
        )
        synthetic_secret = run(
            verification_arguments + ["--verification", verification_file],
            verification_repo, environment=verification_env,
        )
        assert synthetic_secret.returncode != 0
        print("通过：[UNIT/CONTRACT] 验证附件拒绝目标别名、疑似凭据及 dry-run 追加", flush=True)

        write_verification(
            verification_file, verification_repo,
            verification_artifacts / f"ai-support-{VERSION}.tar.gz",
            body="公开下载、Latest 与匿名安装结果已核对，未包含受限现场信息。",
        )
        require_success(
            run(verification_arguments + ["--verification", verification_file], verification_repo,
                environment=verification_env),
            "仅已发布 Release 追加唯一验证附件",
        )
        assert {item.name for item in verification_assets.iterdir()} == {
            f"ai-support-{VERSION}.tar.gz", "SHA256SUMS", "get.sh", verification_file.name,
        }
        require_success(
            run(verification_arguments, verification_repo, environment=verification_env),
            "已有四项资产的已发布版本仍回下载核对三项核心资产",
        )
        original_verification = (verification_assets / verification_file.name).read_bytes()
        uploads_before_conflict = sum(
            json.loads(line)[:2] == ["release", "upload"]
            for line in Path(verification_env["FAKE_GH_LOG"]).read_text(encoding="utf-8").splitlines()
        )
        write_verification(
            verification_file, verification_repo,
            verification_artifacts / f"ai-support-{VERSION}.tar.gz",
            body="此份不同的公开结论不能替换已经上传的同名附件。",
        )
        conflicting_verification = run(
            verification_arguments + ["--verification", verification_file], verification_repo,
            environment=verification_env,
        )
        assert conflicting_verification.returncode != 0
        assert (verification_assets / verification_file.name).read_bytes() == original_verification
        uploads_after_conflict = sum(
            json.loads(line)[:2] == ["release", "upload"]
            for line in Path(verification_env["FAKE_GH_LOG"]).read_text(encoding="utf-8").splitlines()
        )
        assert uploads_after_conflict == uploads_before_conflict
        print("通过：[UNIT/CONTRACT] 已发布版本仅可追加一次且同名不同内容绝不覆盖", flush=True)

        query_repo, query_remote, query_artifacts, query_receipt, query_env = formal_fixture(
            base, temporary, "release-query-error", checks,
        )
        query_env["FAKE_GH_API_ERROR"] = "1"
        query_publish = query_repo / "scripts/publish-release.sh"
        query_result = run([
            query_publish, "--publish", VERSION, "--artifacts", query_artifacts,
            "--target-receipt", query_receipt,
        ], query_repo, environment=query_env)
        assert query_result.returncode != 0
        assert run(["git", "tag", "--list"], query_repo).stdout == ""
        assert run(["git", "ls-remote", "--tags", query_remote], query_repo).stdout == ""
        print("通过：[UNIT/CONTRACT] Release 查询鉴权/网络错误不被误判为不存在", flush=True)

        conflict_repo, conflict_remote, conflict_artifacts, conflict_receipt, conflict_env = formal_fixture(
            base, temporary, "remote-conflict", checks,
        )
        conflict_seed = clone_repository(base, temporary / "remote-conflict-seed")
        (conflict_seed / "README.md").write_text("different release commit\n", encoding="utf-8")
        commit(conflict_seed, "different release")
        require_success(run([
            "git", "-c", "user.name=Release Identity Test", "-c", "user.email=release@example.invalid",
            "tag", "-a", VERSION, "-m", "conflicting tag",
        ], conflict_seed), "创建冲突 tag")
        require_success(run(["git", "remote", "remove", "origin"], conflict_seed), "移除冲突夹具默认远端")
        require_success(run(["git", "remote", "add", "origin", conflict_remote], conflict_seed), "登记冲突远端")
        require_success(run([
            "git", "push", "--atomic", "origin", "HEAD:refs/heads/main", f"refs/tags/{VERSION}:refs/tags/{VERSION}",
        ], conflict_seed), "推送冲突远端")
        conflict_publish = conflict_repo / "scripts/publish-release.sh"
        conflict_result = run([
            conflict_publish, "--publish", VERSION, "--artifacts", conflict_artifacts,
            "--target-receipt", conflict_receipt,
        ], conflict_repo, environment=conflict_env)
        assert conflict_result.returncode != 0
        assert run(["git", "tag", "--list"], conflict_repo).stdout == ""
        assert not Path(conflict_env["FAKE_GH_STATE"]).exists()
        print("通过：[UNIT/CONTRACT] 远端同名 tag 指向其他提交时在本地变更和 Release 前阻止", flush=True)

        publish_source = publish.read_text(encoding="utf-8")
        for required in (
            "gh release create", "--draft", "gh release download",
            "--pattern \"$ARCHIVE_NAME\"", "--pattern SHA256SUMS", "--pattern get.sh",
            "remote get-url origin", "statusX7/ai-support",
            "probe_remote_tag", "verify_remote_main", "gh release upload", "--clobber",
            "gh release edit", "--draft=false", "--latest", "release_state_from_file",
            'releases/latest" --jq',
        ):
            assert required in publish_source, required
        assert publish_source.index("gh release download") < publish_source.index("--draft=false")
        print("通过：[STATIC] 单一入口在正式发布前回下载 draft 并复核 tag/资产", flush=True)

        print("发布身份专项完成：37 项通过，0 失败；仅为 TARGET-A 上的隔离机制测试，不访问真实远端或业务实例。")


if __name__ == "__main__":
    main()
