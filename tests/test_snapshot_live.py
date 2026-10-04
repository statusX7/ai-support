#!/usr/bin/env python3
"""快照预检的实时目录竞态；只执行生产函数和隔离的合成文件系统夹具。"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import re
import shutil
import select
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/snapshot.sh"
AREA = ROOT / ".work/v1.2.1"
REAL_FIND = shutil.which("find")
REAL_DU = shutil.which("du")
REAL_PYTHON = shutil.which("python3")


def production_function(name: str, source=SOURCE) -> str:
    text = source.read_text(encoding="utf-8")
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", text, re.M | re.S)
    if not match:
        raise AssertionError("未找到生产快照函数：" + name)
    return match[0]


FIND_WRAPPER = r'''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
result=subprocess.run([os.environ['SNAPSHOT_FIXTURE_REAL_FIND'],*sys.argv[1:]],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
mode=os.environ.get('SNAPSHOT_FIXTURE_FIND_MODE','')
if mode=='vanish':
    target=pathlib.Path(os.environ['SNAPSHOT_FIXTURE_REMOVE'])
    assert target.name.startswith('session-') or target.name.startswith('fixture-')
    if target.is_dir(): target.rmdir()
    else: target.unlink()
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
if mode=='io_error':
    sys.stderr.write('find: synthetic read failure: Input/output error\n')
    sys.exit(1)
sys.exit(result.returncode)
'''


DU_WRAPPER = r'''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
result=subprocess.run([os.environ['SNAPSHOT_FIXTURE_REAL_DU'],*sys.argv[1:]],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
sys.stdout.buffer.write(result.stdout)
if os.environ.get('SNAPSHOT_FIXTURE_DU_MODE')=='vanish':
    target=pathlib.Path(os.environ['SNAPSHOT_FIXTURE_REMOVE'])
    assert target.name.startswith('session-')
    target.rmdir()
    sys.stderr.write('du: synthetic short-lived lock: No such file or directory\n')
    sys.exit(1)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
'''


PYTHON_WRAPPER = r'''#!/usr/bin/python3
import errno, os, stat, sys
mode=os.environ.get('SNAPSHOT_FIXTURE_FIND_MODE','')
if not mode or sys.argv[1:2] != ['-']:
    os.execv(os.environ['SNAPSHOT_FIXTURE_REAL_PYTHON'],['python3',*sys.argv[1:]])
source=sys.stdin.read()
sys.argv=sys.argv[1:]
original_stat=os.stat
original_open=os.open
target=os.environ.get('SNAPSHOT_FIXTURE_REMOVE','')
removed=False
phase=os.environ.get('SNAPSHOT_FIXTURE_VANISH_PHASE','after_stat')
def remove_target(name):
    global removed
    assert name.startswith('session-') or name.startswith('fixture-')
    removed=True
    if stat.S_ISDIR(original_stat(target,follow_symlinks=False).st_mode): os.rmdir(target)
    else: os.unlink(target)
def scan_stat(name, *args, **kwargs):
    selected=kwargs.get('dir_fd') is not None and name==os.path.basename(target)
    if mode=='vanish' and not removed and selected and phase=='before_stat':
        remove_target(name)
    result=original_stat(name,*args,**kwargs)
    if kwargs.get('dir_fd') is not None:
        if mode=='io_error':
            raise OSError(errno.EIO,'synthetic read failure')
        if mode=='vanish' and not removed and selected and phase=='after_stat':
            remove_target(name)
    return result
def scan_open(name,*args,**kwargs):
    result=original_open(name,*args,**kwargs)
    if mode=='vanish' and not removed and kwargs.get('dir_fd') is not None and name==os.path.basename(target) and phase=='after_open':
        remove_target(name)
    return result
os.stat=scan_stat
os.open=scan_open
exec(compile(source,'<production-snapshot-scan>','exec'),{'__name__':'__main__'})
'''


class SnapshotLiveTests(unittest.TestCase):
    def setUp(self):
        AREA.mkdir(parents=True, exist_ok=True)
        self.base = Path(tempfile.mkdtemp(prefix="snapshot-live-", dir=AREA))
        self.base.chmod(0o700)
        self.tree = self.base / "data/runtime"
        self.tree.mkdir(parents=True)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for name, text in (("find", FIND_WRAPPER), ("du", DU_WRAPPER), ("python3", PYTHON_WRAPPER)):
            target = self.bin / name
            target.write_text(text, encoding="utf-8")
            target.chmod(0o700)
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "LC_ALL": "C", "SNAPSHOT_FIXTURE_REAL_FIND": REAL_FIND,
                    "SNAPSHOT_FIXTURE_REAL_DU": REAL_DU, "SNAPSHOT_FIXTURE_REAL_PYTHON": REAL_PYTHON}

    def tearDown(self):
        shutil.rmtree(self.base)
        self.assertFalse(self.base.exists())

    def run_function(self, mode="validate", extra=None, unprivileged=False):
        definitions = "\n".join(production_function(name) for name in
                                ("snapshot_scan_sources", "snapshot_validate_tree", "snapshot_capacity_check", "copy_snapshot_tree", "snapshot_assert_provider_settled", "snapshot_assert_atomic_config_settled"))
        script = "set -euo pipefail\ndie(){ printf '%s\\n' \"$*\" >&2; exit 1; }\ninfo(){ :; }\n" + definitions
        script += '\nDEPLOY_DIR=$1\nSTAGING="$1/staging"\nVERSIONS_DIR="$1"\nQUIET=1\nSNAPSHOT_MIN_FREE_MB_VALUE=0\n'
        if mode == "capacity":
            script += 'SNAPSHOT_SOURCE_PATHS=("$1/data/runtime" "${1}/other")\nsnapshot_capacity_check\nprintf "%s\\n" "$SNAPSHOT_SOURCE_KIB"\n'
        elif mode == "copy":
            script += 'copy_snapshot_tree data/runtime\n'
        elif mode == "pending":
            script += 'snapshot_assert_provider_settled\n'
        elif mode == "atomic":
            script += 'snapshot_assert_atomic_config_settled\n'
        else:
            script += 'snapshot_validate_tree data/runtime\n'
        environment = {**self.env, **(extra or {})}
        demote = None
        if unprivileged:
            environment["PATH"] = "/usr/bin:/bin"
            self.base.chmod(0o755)
            (self.base / "data").chmod(0o755)
            self.tree.chmod(0o755)
            if os.geteuid() == 0:
                def demote():
                    os.setgroups([])
                    os.setgid(65534)
                    os.setuid(65534)
        return subprocess.run(["bash", "-c", script, "--", "."], cwd=self.base,
                              env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=8, check=False, preexec_fn=demote)

    def test_01_disappearing_lock(self):
        """列举完成后实际删除的短命锁不能误报特殊文件。"""
        lock = self.tree / ("session-" + "a" * 64 + ".json.lock")
        for phase in ("before_stat", "after_stat", "after_open"):
            with self.subTest(phase=phase):
                lock.mkdir()
                result = self.run_function(extra={"SNAPSHOT_FIXTURE_FIND_MODE": "vanish", "SNAPSHOT_FIXTURE_REMOVE": str(lock), "SNAPSHOT_FIXTURE_VANISH_PHASE": phase})
                self.assertFalse(lock.exists())
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_02_disappearing_temporary_file(self):
        """普通临时文件消失同样仅影响实时预检，不伪装成链接。"""
        temporary = self.tree / "fixture-temporary.json"
        for phase in ("before_stat", "after_stat"):
            with self.subTest(phase=phase):
                temporary.write_text("synthetic", encoding="utf-8")
                result = self.run_function(extra={"SNAPSHOT_FIXTURE_FIND_MODE": "vanish", "SNAPSHOT_FIXTURE_REMOVE": str(temporary), "SNAPSHOT_FIXTURE_VANISH_PHASE": phase})
                self.assertFalse(temporary.exists())
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_03_existing_unsafe_types(self):
        """现存符号链接、悬空链接、FIFO和socket全部拒绝。"""
        regular = self.tree / "fixture-regular"
        regular.write_text("synthetic", encoding="utf-8")
        for kind in ("symlink", "dangling", "fifo", "socket"):
            with self.subTest(kind=kind):
                target = self.tree / "fixture-unsafe"
                handle = None
                if kind == "symlink":
                    target.symlink_to(regular)
                elif kind == "dangling":
                    target.symlink_to(self.tree / "missing")
                elif kind == "fifo":
                    os.mkfifo(target)
                else:
                    handle = socket.socket(socket.AF_UNIX)
                    # 使用短相对地址，避免Unix socket路径长度掩盖类型检查。
                    prior = Path.cwd()
                    try:
                        os.chdir(self.tree)
                        handle.bind(target.name)
                    finally:
                        os.chdir(prior)
                try:
                    self.assertNotEqual(self.run_function().returncode, 0)
                finally:
                    if handle:
                        handle.close()
                    target.unlink()
        regular.unlink()
        self.tree.rmdir()
        self.assertNotEqual(self.run_function().returncode, 0)
        self.tree.symlink_to(self.base / "missing")
        self.assertNotEqual(self.run_function().returncode, 0)
        self.tree.unlink()
        self.tree.mkdir()

    def test_04_unsafe_names(self):
        """原有换行、回车、制表符及反斜杠名字仍拒绝。"""
        for character in ("\n", "\r", "\t", "\\"):
            with self.subTest(character=repr(character)):
                target = self.tree / ("fixture-" + character + "name")
                target.write_text("synthetic", encoding="utf-8")
                try:
                    self.assertNotEqual(self.run_function().returncode, 0)
                finally:
                    target.unlink()

    def test_05_find_failure_is_not_lost(self):
        """预检元数据EIO及停后find部分输出的非零结果都不能给出通过。"""
        (self.tree / "fixture-regular").write_text("synthetic", encoding="utf-8")
        result = self.run_function(extra={"SNAPSHOT_FIXTURE_FIND_MODE": "io_error"})
        self.assertNotEqual(result.returncode, 0)
        result = self.run_function("copy", {"SNAPSHOT_FIXTURE_FIND_MODE": "io_error"})
        self.assertNotEqual(result.returncode, 0)

    def test_06_permission_error_is_rejected(self):
        """真实无访问权限子目录必须失败，不属于ENOENT竞态。"""
        blocked = self.tree / "fixture-unreadable"
        blocked.mkdir(mode=0o000)
        try:
            result = self.run_function(unprivileged=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
        finally:
            blocked.chmod(0o700)

    def test_07_capacity_live_race_and_errors(self):
        """容量预检容忍同类锁消失，但保留真实读取错误。"""
        (self.base / "other").mkdir()
        (self.tree / "fixture-allocated").write_bytes(b"x" * 4096)
        lock = self.tree / ("session-" + "b" * 64 + ".json.lock")
        lock.mkdir()
        result = self.run_function("capacity", {"SNAPSHOT_FIXTURE_FIND_MODE": "vanish", "SNAPSHOT_FIXTURE_DU_MODE": "vanish", "SNAPSHOT_FIXTURE_REMOVE": str(lock)})
        self.assertFalse(lock.exists())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(int(result.stdout.strip()), 0)
        self.assertNotEqual(self.run_function("capacity", {"SNAPSHOT_FIXTURE_FIND_MODE": "io_error"}).returncode, 0)

    def test_08_capacity_uses_allocated_blocks_and_hardlink_dedup(self):
        """实际分配块、稀疏文件和跨根硬链接计数保持保守。"""
        other = self.base / "other"
        other.mkdir()
        regular = self.tree / "fixture-regular"
        regular.write_bytes(b"x" * 8192)
        os.link(regular, other / "fixture-hardlink")
        with (self.tree / "fixture-sparse").open("wb") as stream:
            stream.truncate(64 * 1024 * 1024)
        expected = subprocess.run([REAL_DU, "-sk", "--", str(self.tree), str(other)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True, timeout=4)
        allocated = sum(int(line.split()[0]) for line in expected.stdout.splitlines())
        result = self.run_function("capacity")
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = int(result.stdout.strip())
        self.assertGreaterEqual(actual, allocated)
        self.assertLessEqual(actual, allocated + 5)
        self.assertLess(actual, 65536)

    def test_09_stopped_copy_stays_strict(self):
        """停服务后的实际复制不使用实时预检的竞态宽容。"""
        stable = self.tree / "fixture-regular"
        stable.write_text("synthetic-persisted-state", encoding="utf-8")
        self.assertEqual(self.run_function("copy").returncode, 0)
        self.assertEqual((self.base / "staging/payload/data/runtime/fixture-regular").read_text(), stable.read_text())
        lock = self.tree / ("session-" + "c" * 64 + ".json.lock")
        lock.mkdir()
        result = self.run_function("copy", {"SNAPSHOT_FIXTURE_FIND_MODE": "vanish", "SNAPSHOT_FIXTURE_REMOVE": str(lock)})
        self.assertNotEqual(result.returncode, 0)
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("^(n8n|anythingllm|provider-adapter)$", source)
        self.assertLess(source.index('docker_compose "$DEPLOY_DIR" stop'), source.index('copy_snapshot_tree()'))

    def test_10_native_live_directory_scans(self):
        """不注入任何扫描器的真实活跃锁目录，预检及容量都不误报。"""
        (self.base / "other").mkdir()
        (self.tree / "fixture-allocated").write_bytes(b"x" * 4096)
        stopped = threading.Event()
        errors = []

        def churn():
            while not stopped.is_set():
                for index in range(8):
                    lock = self.tree / ("session-" + f"{index:064x}" + ".json.lock")
                    try:
                        lock.mkdir()
                        lock.rmdir()
                    except OSError as error:
                        errors.append(type(error).__name__)
                        stopped.set()

        worker = threading.Thread(target=churn)
        worker.start()
        try:
            for _ in range(12):
                for mode in ("validate", "capacity"):
                    result = self.run_function(mode, {"PATH": "/usr/bin:/bin"})
                    self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(errors, [])
        finally:
            stopped.set()
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())

    def test_11_pending_provider_transaction_is_rejected(self):
        """任何尚存窗口事务均拒绝快照，不读敏感内容或自动恢复。"""
        config = self.base / "config"
        config.mkdir()
        self.assertEqual(self.run_function("pending").returncode, 0)
        pending = config / "provider-pool-transaction.json"
        for kind in ("file", "dangling", "fifo"):
            with self.subTest(kind=kind):
                if kind == "file":
                    pending.write_text('{"phase":"applying"}', encoding="utf-8")
                elif kind == "dangling":
                    pending.symlink_to(config / "missing")
                else:
                    os.mkfifo(pending)
                try:
                    result = self.run_function("pending")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("3→10→12", result.stderr)
                    self.assertTrue(pending.exists() or pending.is_symlink())
                finally:
                    pending.unlink()

    def test_12_shared_pool_lock_serializes_a_short_commit(self):
        """原生flock共享锁与Python短提交互斥，释放后提交正常继续。"""
        config = self.base / "config"
        config.mkdir()
        (config / "provider-pool-applied.json").write_text('{"revision":1}', encoding="utf-8")
        (self.base / ".env").write_text("SYNTHETIC_REVISION=1\n", encoding="utf-8")
        definitions = "\n".join(production_function(name) for name in ("snapshot_acquire_provider_lock", "snapshot_release_provider_lock", "snapshot_assert_provider_settled"))
        script = "set -euo pipefail\ndie(){ exit 1; }\nDEPLOY_DIR=.\n" + definitions
        script += '\ntrap snapshot_release_provider_lock EXIT\nsnapshot_acquire_provider_lock\nsnapshot_assert_provider_settled\nprintf "LOCKED\\n"\nread -r release\nsnapshot_release_provider_lock\n'
        reader = subprocess.Popen(["bash", "-c", script], cwd=self.base, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        writer = None
        try:
            self.assertTrue(select.select([reader.stdout], [], [], 3)[0])
            self.assertEqual(reader.stdout.readline().strip(), "LOCKED")
            writer_code = "import fcntl,pathlib; p=pathlib.Path('.'); f=(p/'config/provider-pool.lock').open('a'); fcntl.flock(f,fcntl.LOCK_EX); (p/'.env').write_text('SYNTHETIC_REVISION=2\\n'); (p/'config/provider-pool-applied.json').write_text('{\"revision\":2}'); print('COMMITTED',flush=True)"
            writer = subprocess.Popen([sys.executable, "-c", writer_code], cwd=self.base, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertFalse(select.select([writer.stdout], [], [], 0.15)[0])
            self.assertEqual((self.base / ".env").read_text(), "SYNTHETIC_REVISION=1\n")
            self.assertEqual((config / "provider-pool-applied.json").read_text(), '{"revision":1}')
            reader.communicate("release\n", timeout=3)
            output, error = writer.communicate(timeout=3)
            self.assertEqual(reader.returncode, 0)
            self.assertEqual(writer.returncode, 0, error)
            self.assertEqual(output.strip(), "COMMITTED")
            self.assertEqual((self.base / ".env").read_text(), "SYNTHETIC_REVISION=2\n")
            source = SOURCE.read_text(encoding="utf-8")
            stop = source.index('docker_compose "$DEPLOY_DIR" stop')
            acquired = source.index('\nsnapshot_acquire_provider_lock\n', stop)
            root_copy = source.index('for name in "${ROOT_FILES[@]}"', acquired)
            config_copy = source.index('\ncopy_snapshot_tree config\n', root_copy)
            secrets_copy = source.index('copy_snapshot_tree secrets', config_copy)
            released = source.index('\nsnapshot_release_provider_lock\n', secrets_copy)
            database_dump = source.index("pg_dump --username", released)
            self.assertLess(stop, acquired)
            self.assertLess(acquired, root_copy)
            self.assertLess(root_copy, config_copy)
            self.assertLess(config_copy, secrets_copy)
            self.assertLess(secrets_copy, released)
            self.assertLess(released, database_dump)
            self.assertNotIn('config knowledge', source[released:])
            cleanup = production_function("cleanup")
            self.assertLess(cleanup.index('snapshot_release_provider_lock'), cleanup.index('docker_compose'))
            failed = subprocess.run(["bash", "-c", "set -euo pipefail\nDEPLOY_DIR=.\ndie(){ exit 1; }\n" + definitions + '\ntrap snapshot_release_provider_lock EXIT\nsnapshot_acquire_provider_lock\nfalse\n'],
                                    cwd=self.base, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
            self.assertEqual(failed.returncode, 1)
            released_after_failure = subprocess.run(["flock", "--exclusive", "--nonblock", str(config / "provider-pool.lock"), "true"], timeout=3)
            self.assertEqual(released_after_failure.returncode, 0)
        finally:
            for process in (reader, writer):
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=3)

    def test_13_pending_knowledge_migration_is_rejected(self):
        """知识迁移的任何尚存标记都拒绝，不解析坏文件或跟随链接。"""
        self.assertEqual(self.run_function("pending").returncode, 0)
        pending = self.tree / "knowledge-migration.json"
        for kind in ("file", "malformed", "dangling", "fifo", "directory"):
            with self.subTest(kind=kind):
                if kind in ("file", "malformed"):
                    pending.write_text('{"state":"applying"}' if kind == "file" else "{", encoding="utf-8")
                elif kind == "dangling":
                    pending.symlink_to(self.tree / "missing")
                elif kind == "fifo":
                    os.mkfifo(pending)
                else:
                    pending.mkdir()
                try:
                    result = self.run_function("pending")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("知识迁移", result.stderr)
                    self.assertTrue(pending.exists() or pending.is_symlink())
                finally:
                    pending.rmdir() if kind == "directory" else pending.unlink()

    def test_14_same_version_knowledge_capabilities_are_complete_or_absent(self):
        """旧候选全无可用；六模块部分、链接、运行文件缺失及伪装旧代均拒绝。"""
        name = "knowledge_snapshot_modules_check"
        definition = production_function(name)
        self.assertEqual(definition, production_function(name, ROOT / "scripts/rollback.sh"))
        for relative in ("scripts", "n8n", "config"):
            (self.base / relative).mkdir()
        runtime = self.base / "n8n/runtime.js"
        runtime.write_text("synthetic-runtime", encoding="utf-8")
        workflow = self.base / "n8n/workflow.json"
        workflow.write_text('{"meta":{}}', encoding="utf-8")
        modules = [self.base / relative for relative in (
            "scripts/knowledge-component.js", "scripts/knowledge-profile.py",
            "scripts/knowledge-profile.sh", "scripts/knowledge-lexical.py",
            "n8n/admin-query.js", "n8n/knowledge-lexical.js")]

        def run():
            script = "set -euo pipefail\ndie(){ printf '%s\\n' \"$*\" >&2; exit 1; }\n" + definition
            script += '\nknowledge_snapshot_modules_check "$1"\nprintf "%s\\n" "$KNOWLEDGE_SNAPSHOT_HAS_P0"\n'
            return subprocess.run(["bash", "-c", script, "--", str(self.base)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=4)

        self.assertEqual((run().returncode, run().stdout.strip()), (0, "0"))
        for module in modules:
            module.write_text("synthetic-module", encoding="utf-8")
        self.assertEqual((run().returncode, run().stdout.strip()), (0, "1"))
        for module in modules:
            with self.subTest(missing=module.name):
                module.unlink()
                self.assertNotEqual(run().returncode, 0)
                module.write_text("synthetic-module", encoding="utf-8")
        for kind in ("symlink", "dangling", "fifo"):
            with self.subTest(kind=kind):
                modules[0].unlink()
                if kind == "fifo":
                    os.mkfifo(modules[0])
                else:
                    modules[0].symlink_to(runtime if kind == "symlink" else self.base / "missing")
                self.assertNotEqual(run().returncode, 0)
                modules[0].unlink()
                modules[0].write_text("synthetic-module", encoding="utf-8")
        runtime.unlink()
        self.assertNotEqual(run().returncode, 0)
        runtime.write_text("synthetic-runtime", encoding="utf-8")
        for module in modules:
            module.unlink()
        workflow.write_text(json.dumps({"meta": {"lexicalFileSha256": "a" * 64}}), encoding="utf-8")
        self.assertNotEqual(run().returncode, 0)
        workflow.write_text('{"meta":{}}', encoding="utf-8")
        for filename in ("knowledge-profile.json", "knowledge-lexical.json"):
            with self.subTest(state=filename):
                marker = self.tree / filename
                marker.write_text('{"state":"applied"}', encoding="utf-8")
                self.assertNotEqual(run().returncode, 0)
                marker.unlink()
        applied = self.base / "config/materials-applied.json"
        for field in ("profile_sha256", "lexical_sha256"):
            with self.subTest(projection=field):
                applied.write_text(json.dumps({"state": "applied", "knowledge": {field: "b" * 64}}), encoding="utf-8")
                self.assertNotEqual(run().returncode, 0)
        applied.unlink()
        self.assertEqual(run().returncode, 0)

    def test_15_projection_archive_allowance_is_exact_and_regular(self):
        """只新增精确普通投影文件，目录、相近路径及所有链接类型仍拒绝。"""
        entries = (
            ("payload/data/knowledge-projection.json", tarfile.REGTYPE, 0),
            ("payload/data/knowledge-projection.json", tarfile.DIRTYPE, 1),
            ("payload/data/knowledge-projection.json/child", tarfile.REGTYPE, 1),
            ("payload/data/knowledge-projection-other.json", tarfile.REGTYPE, 1),
            ("payload/data/knowledge-projection.json", tarfile.SYMTYPE, 1),
            ("payload/data/knowledge-projection.json", tarfile.LNKTYPE, 1),
            ("payload/data/knowledge-projection.json", tarfile.FIFOTYPE, 1),
        )
        for index, (name, kind, expected) in enumerate(entries):
            with self.subTest(name=name, kind=kind):
                archive = self.base / f"projection-{index}.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    item = tarfile.TarInfo(name)
                    item.type = kind
                    item.mode = 0o600
                    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                        item.linkname = "payload/data/synthetic-missing"
                    data = b"[]\n" if kind == tarfile.REGTYPE else b""
                    item.size = len(data)
                    output.addfile(item, io.BytesIO(data))
                result = subprocess.run([sys.executable, str(ROOT / "scripts/archive-guard.py"),
                                         str(archive), "--kind", "snapshot"],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=4)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_16_projection_restore_keeps_bytes_and_clears_a_newer_generation(self):
        """调用真实恢复函数：投影逐字恢复0600；旧载荷无投影只移除该普通文件。"""
        rollback = ROOT / "scripts/rollback.sh"
        definitions = "\n".join(production_function(name, rollback) for name in
                                ("validate_optional_version_file", "sync_optional_version_file"))
        source = self.base / "snapshot-projection.json"
        destination = self.base / "data/knowledge-projection.json"
        untouched = self.base / "data/synthetic-unrelated.json"
        untouched.write_text("keep", encoding="utf-8")

        def run():
            script = "set -euo pipefail\ndie(){ exit 1; }\ninfo(){ :; }\n" + definitions
            script += '\nvalidate_optional_version_file "$1" "$2" data/knowledge-projection.json\n'
            script += 'sync_optional_version_file "$1" "$2" 0600 data/knowledge-projection.json\n'
            return subprocess.run(["bash", "-c", script, "--", str(source), str(destination)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4)

        value = b'[{"filename":"synthetic-projection.md","sha256":"synthetic-digest"}]\n'
        source.write_bytes(value)
        destination.write_text("newer-stale-generation", encoding="utf-8")
        self.assertEqual(run().returncode, 0)
        self.assertEqual(destination.read_bytes(), value)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        source.unlink()
        self.assertEqual(run().returncode, 0)
        self.assertFalse(destination.exists())
        self.assertEqual(untouched.read_text(), "keep")
        for kind in ("symlink", "dangling", "fifo"):
            with self.subTest(destination=kind):
                if kind == "fifo":
                    os.mkfifo(destination)
                else:
                    destination.symlink_to(untouched if kind == "symlink" else source)
                self.assertNotEqual(run().returncode, 0)
                self.assertTrue(destination.exists() or destination.is_symlink())
                self.assertEqual(untouched.read_text(), "keep")
                destination.unlink()

    def test_17_materials_archive_has_a_strict_positive_member_set(self):
        """资料包仅允许固定配置、目录和受管文档；链接、额外成员、重复和超限均拒绝。"""
        guard = ROOT / "scripts/archive-guard.py"

        def archive(name, entries):
            target = self.base / name
            with tarfile.open(target, "w:gz") as output:
                for member_name, kind, data in entries:
                    item = tarfile.TarInfo(member_name)
                    item.type = kind
                    item.mode = 0o700 if kind == tarfile.DIRTYPE else 0o600
                    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                        item.linkname = "../../synthetic-outside"
                    item.size = len(data)
                    output.addfile(item, io.BytesIO(data))
            return target

        valid = archive("materials-valid.tar.gz", [
            ("config", tarfile.DIRTYPE, b""),
            ("config/runtime.yaml", tarfile.REGTYPE, b"schema_version: 2\n"),
            ("config/handoff.yaml", tarfile.REGTYPE, b"handoff: {}\n"),
            ("config/keyword.yaml", tarfile.REGTYPE, b"keyword: {}\n"),
            ("config/menu.yaml", tarfile.REGTYPE, b"welcome: {}\n"),
            ("config/tags.yaml", tarfile.REGTYPE, b"tags: {}\n"),
            ("config/feedback.yaml", tarfile.REGTYPE, b"feedback: {}\n"),
            ("config/prompt.md", tarfile.REGTYPE, b"synthetic prompt"),
            ("knowledge", tarfile.DIRTYPE, b""),
            ("knowledge/catalog.json", tarfile.REGTYPE, b'{"schema_version":2,"libraries":[]}'),
            ("knowledge/kb_1111111111111111", tarfile.DIRTYPE, b""),
            ("knowledge/kb_1111111111111111/sources", tarfile.DIRTYPE, b""),
            ("knowledge/kb_1111111111111111/sources/doc_2222222222222222.md", tarfile.REGTYPE, b"synthetic"),
        ])
        result = subprocess.run([sys.executable, str(guard), str(valid), "--kind", "materials"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)

        invalid = (
            ("materials-missing-required.tar.gz", [("config", tarfile.DIRTYPE, b""),
                                                     ("config/prompt.md", tarfile.REGTYPE, b"x")]),
            ("materials-extra.tar.gz", [("unexpected", tarfile.REGTYPE, b"x")]),
            ("materials-traversal.tar.gz", [("../outside", tarfile.REGTYPE, b"x")]),
            ("materials-link.tar.gz", [("config/prompt.md", tarfile.SYMTYPE, b"")]),
            ("materials-special.tar.gz", [("knowledge/catalog.json", tarfile.FIFOTYPE, b"")]),
            ("materials-duplicate.tar.gz", [("config/prompt.md", tarfile.REGTYPE, b"x"),
                                               ("config/prompt.md", tarfile.REGTYPE, b"y")]),
        )
        for name, entries in invalid:
            with self.subTest(name=name):
                target = archive(name, entries)
                result = subprocess.run([sys.executable, str(guard), str(target), "--kind", "materials"],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=4)
                self.assertNotEqual(result.returncode, 0)
        oversized = archive("materials-oversized.tar.gz", [("config/prompt.md", tarfile.REGTYPE, b"xx")])
        result = subprocess.run([sys.executable, str(guard), str(oversized), "--kind", "materials", "--max-bytes", "1"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=4)
        self.assertNotEqual(result.returncode, 0)

    def test_18_rollback_safety_snapshot_precedes_service_stop(self):
        """默认安全快照需要运行中容器回读，必须先于版本回滚自己的停服务边界。"""
        source = (ROOT / "scripts/rollback.sh").read_text(encoding="utf-8")
        safety = source.index('SAFETY_ID=$("${SCRIPT_DIR}/snapshot.sh"')
        stop = source.index('docker_compose "$DEPLOY_DIR" stop "${PAUSED_APP_SERVICES[@]}"')
        mutation = source.index('MUTATION_STARTED=1', safety)
        self.assertLess(safety, stop)
        self.assertLess(stop, mutation)

    def test_19_atomic_config_recovery_is_never_snapshotted(self):
        """未决日志及无归属秘密副本均保留现场并阻止混代快照。"""
        self.assertEqual(self.run_function("atomic").returncode, 0)
        for name in (".env.crispai-atomic.json", ".env.crispai-atomic.next",
                     ".env.source.fixture", ".env.tmp.fixture"):
            with self.subTest(name=name):
                target = self.base / name
                target.write_text("synthetic restricted recovery material\n", encoding="utf-8")
                target.chmod(0o600)
                try:
                    result = self.run_function("atomic")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(target.is_file())
                finally:
                    target.unlink()


    def test_20_restored_runtime_is_readable_by_real_run_user(self):
        """实际恢复权限后，UID1000可读取状态，知识控制投影仍由root签发。"""
        if os.geteuid() != 0:
            self.skipTest("真实运行用户权限验证需要root")
        with tempfile.TemporaryDirectory(prefix="crispai-runtime-owner-") as temporary:
            base = Path(temporary)
            base.chmod(0o755)
            deploy, payload = base / "deploy", base / "payload"
            for directory in (deploy / "data/runtime", payload / "data/runtime", payload / "tmp"):
                directory.mkdir(parents=True)
            for ancestor in (deploy, deploy / "data"):
                ancestor.chmod(0o755)
            content = b'{"started_at":1,"completed_at":2}\n'
            scheduler = payload / "data/runtime/scheduler-health.json"
            scheduler.write_bytes(content)
            scheduler.chmod(0o600)
            projection = payload / "data/runtime/knowledge-map.json"
            projection.write_bytes(b'{"schema_version":2,"documents":[]}\n')
            projection.chmod(0o600)
            old_state = deploy / "data/runtime/fixture-old.json"
            old_state.write_bytes(b'{"old":true}\n')
            function = production_function("restore_snapshot_tree", ROOT / "scripts/rollback.sh")
            script = 'set -euo pipefail\nsource "$1/scripts/common.sh"\nDEPLOY_DIR=$2\nPAYLOAD=$3\n' + function
            script += '\nrestore_snapshot_tree data/runtime\n'
            result = subprocess.run(["bash", "-c", script, "--", str(ROOT), str(deploy), str(payload)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            restored = deploy / "data/runtime/scheduler-health.json"
            self.assertEqual(restored.read_bytes(), content)
            self.assertEqual((restored.stat().st_uid, restored.stat().st_gid, restored.stat().st_mode & 0o777),
                             (1000, 1000, 0o600))
            control = deploy / "data/runtime/knowledge-map.json"
            self.assertEqual(control.read_bytes(), projection.read_bytes())
            self.assertEqual((control.stat().st_uid, control.stat().st_gid, control.stat().st_mode & 0o777),
                             (0, 1000, 0o640))
            self.assertFalse(old_state.exists())
            def run_user():
                os.setgroups([])
                os.setgid(1000)
                os.setuid(1000)
            reading = subprocess.run([sys.executable, "-c",
                                      "import pathlib,sys;sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes())",
                                      str(restored)], preexec_fn=run_user, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, timeout=5)
            self.assertEqual(reading.returncode, 0, reading.stderr)
            self.assertEqual(reading.stdout, content)

    def test_21_legacy_canonical_is_counted_and_copied(self):
        """旧版本已有的资料原文包也必须进入容量和快照，缺省旧实例不凭空创建。"""
        source = SOURCE.read_text(encoding="utf-8")
        selection = source.split("SNAPSHOT_HAS_MATERIALS_CANONICAL=0\n", 1)[1].split("\nsnapshot_validate_file() {", 1)[0]
        selection = "SNAPSHOT_HAS_MATERIALS_CANONICAL=0\n" + selection
        blocks = re.findall(r"^if \(\( SNAPSHOT_HAS_MATERIALS_CANONICAL \)\); then\n.*?^fi$", source, re.M | re.S)
        self.assertEqual(len(blocks), 2)
        canonical = self.base / "backups/config-history/materials.applied.tar.gz"
        canonical.parent.mkdir(parents=True)
        with tarfile.open(canonical, "w:gz") as archive:
            member = tarfile.TarInfo("config/prompt.md")
            data = b"synthetic legacy prompt\n"
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        expected = canonical.read_bytes()
        script = "set -euo pipefail\ndie(){ printf '%s\\n' \"$*\" >&2; exit 1; }\n"
        script += production_function("snapshot_version_at_least")
        script += '\nDEPLOY_DIR=$1\nSTAGING="$1/staging"\nVERSION_VALUE=$2\nSNAPSHOT_SOURCE_PATHS=()\n'
        script += selection + "\n" + "\n".join(blocks) + '\nprintf "%s\\n" "${#SNAPSHOT_SOURCE_PATHS[@]}"\n'
        result = subprocess.run(["bash", "-c", script, "--", str(self.base), "v1.2.1"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1")
        archived = self.base / "staging/payload/backups/config-history/materials.applied.tar.gz"
        self.assertEqual(archived.read_bytes(), expected)
        self.assertEqual(archived.stat().st_mode & 0o777, 0o600)
        archived.unlink()
        canonical.unlink()
        absent = subprocess.run(["bash", "-c", script, "--", str(self.base), "v1.1.0"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        self.assertEqual(absent.returncode, 0, absent.stderr)
        self.assertEqual(absent.stdout.strip(), "0")
        self.assertFalse(archived.exists())
        required = subprocess.run(["bash", "-c", script, "--", str(self.base), "v1.3.0"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        self.assertNotEqual(required.returncode, 0)


    def test_22_failed_update_rewind_preserves_new_accepted_delivered_and_human_facts(self):
        import hashlib
        import copy

        website = "synthetic-rewind-website"
        session = "session_synthetic_rewind_01"
        key = hashlib.sha256((website + "\0" + session).encode()).hexdigest()
        name = "session-" + key + ".json"
        original = {
            "schema_version": 2, "website_id": website, "session_id": session,
            "jobs": [{"id": "a" * 64, "status": "received"}],
            "outgoing": {}, "last_human_at": 0,
        }
        variants = [
            ("same", True),
            ("derived_only", True),
            ("new_job", False),
            ("new_owned", False),
            ("new_outgoing", False),
            ("new_human", False),
            ("legacy_changed", False),
            ("invalid_json", False),
            ("wrong_owned_bucket", False),
            ("old_outgoing_known_owned", True),
        ]
        for label, allowed in variants:
            with self.subTest(label=label):
                case = self.base / ("rewind-" + label)
                live = case / "deploy"
                payload = case / "payload"
                current = live / "data/runtime"
                archived = payload / "data/runtime"
                current.mkdir(parents=True)
                archived.mkdir(parents=True)
                old = copy.deepcopy(original)
                fresh = copy.deepcopy(original)
                if label == "derived_only":
                    fresh["jobs"][0].update(status="processing", lease_until=99, plan={"content": "合成计划"})
                elif label == "new_job":
                    fresh["jobs"].append({"id": "b" * 64, "status": "done"})
                elif label == "new_outgoing":
                    fresh["outgoing"]["8"] = {"status": "sent"}
                elif label == "new_human":
                    fresh["last_human_at"] = 10
                elif label == "legacy_changed":
                    old = {"aiEnabled": True}
                    fresh = {"aiEnabled": False}
                elif label == "old_outgoing_known_owned":
                    old["outgoing"]["9"] = {"status": "unknown"}
                    fresh["outgoing"]["9"] = {"status": "sent"}
                (archived / name).write_text(json.dumps(old))
                (current / name).write_text("{" if label == "invalid_json" else json.dumps(fresh))
                if label in ("new_owned", "wrong_owned_bucket", "old_outgoing_known_owned"):
                    fingerprint = "9" if label != "new_owned" else "8"
                    bucket = "08" if label == "wrong_owned_bucket" else format(int(fingerprint) % 256, "02x")
                    (current / ("owned-" + key + "-" + bucket + ".json")).write_text(
                        json.dumps({"schema_version": 1, "fingerprints": [fingerprint]})
                    )
                files = [file for file in case.rglob("*") if file.is_file()]
                before = {str(file): file.read_bytes() for file in files}
                script = "set -euo pipefail\nDEPLOY_DIR=$1\nPAYLOAD=$2\n"
                script += production_function(
                    "failed_update_assert_runtime_rewind_safe", ROOT / "scripts/rollback.sh"
                )
                script += "\nfailed_update_assert_runtime_rewind_safe\n"
                result = subprocess.run(
                    ["bash", "-c", script, "--", str(live), str(payload)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
                )
                self.assertEqual(result.returncode == 0, allowed, (label, result.stderr))
                self.assertEqual({str(file): file.read_bytes() for file in files}, before)
                if not allowed:
                    self.assertIn("拒绝", result.stderr.decode())


    def test_23_maintenance_component_readiness_retains_business_failures(self):
        # 只验证真实兼容入口对结构化报告的分层合同；doctor 此处是明确的报告夹具，
        # 不替代真实 doctor 集成、TARGET 服务或客服业务验收。
        fixture = self.base / "health-contract"
        scripts = fixture / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/healthcheck.sh", scripts / "healthcheck.sh")
        doctor = scripts / "doctor.sh"
        doctor.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            'printf "%s\\n" "$HEALTH_CONTRACT_REPORT"\nexit "$HEALTH_CONTRACT_EXIT"\n'
        )
        doctor.chmod(0o750)
        problem = {
            "id": "runtime.answer_responsibilities", "status": "FAIL",
            "name": "应答责任", "summary": "责任产物损坏 0；未知发送 0；未完成故障 2",
        }
        report = {
            "schema_version": 1, "scope": "local", "version": "v1.3.0",
            "checked_at": "synthetic", "results": [problem],
            "summary": {"pass": 0, "warn": 0, "fail": 1, "skip": 0},
        }
        variants = [
            ("ordinary", report, False, 1, 1),
            ("maintenance", report, True, 1, 0),
            ("artifact", {**report, "results": [{**problem, "summary": "责任产物损坏 1；未知发送 0；"}]}, True, 1, 1),
            ("unknown-send", {**report, "results": [{**problem, "summary": "责任产物损坏 0；未知发送 1；"}]}, True, 1, 1),
            ("other-component", {**report, "results": [{**problem, "id": "runtime.state"}]}, True, 1, 1),
            ("duplicate-id", {**report, "results": [problem, {**problem, "status": "PASS"}]}, True, 1, 1),
            ("two-failures", {**report, "results": [problem, {**problem, "id": "runtime.state"}], "summary": {**report["summary"], "fail": 2}}, True, 1, 1),
            ("invalid-json", "{", True, 1, 1),
            ("healthy", {**report, "results": [{**problem, "status": "PASS"}], "summary": {**report["summary"], "pass": 1, "fail": 0}}, True, 0, 0),
        ]
        for label, value, maintenance, doctor_exit, expected in variants:
            with self.subTest(label=label):
                environment = os.environ.copy()
                environment.update(
                    HEALTH_CONTRACT_REPORT=value if isinstance(value, str) else json.dumps(value),
                    HEALTH_CONTRACT_EXIT=str(doctor_exit),
                )
                arguments = ["bash", str(scripts / "healthcheck.sh"), "--application", "--json"]
                if maintenance:
                    arguments.append("--installation-in-progress")
                result = subprocess.run(arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                self.assertEqual(result.returncode, expected, (label, result.stderr))
                if label != "invalid-json":
                    self.assertEqual(json.loads(result.stdout), value)
                if label == "maintenance":
                    self.assertIn("未通过客服业务验收", result.stderr.decode())
                    self.assertEqual(json.loads(result.stdout)["summary"]["fail"], 1)


        environment = os.environ.copy()
        environment.update(HEALTH_CONTRACT_REPORT=json.dumps(report), HEALTH_CONTRACT_EXIT="1")
        human = subprocess.run(
            ["bash", str(scripts / "healthcheck.sh"), "--application", "--installation-in-progress"],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
        )
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("[故障] 应答责任", human.stdout.decode())
        self.assertIn("失败 1", human.stdout.decode())
        self.assertIn("未通过客服业务验收", human.stderr.decode())


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SnapshotLiveTests))
    failures = len(result.failures) + len(result.errors)
    print(f"UNIT 快照实时预检：{result.testsRun - failures} 通过，{failures} 失败；不连接Docker或目标机。")
    sys.exit(0 if result.wasSuccessful() else 1)
