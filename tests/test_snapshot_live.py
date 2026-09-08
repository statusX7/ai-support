#!/usr/bin/env python3
"""快照预检的实时目录竞态；只执行生产函数和隔离的合成文件系统夹具。"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import select
import socket
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/snapshot.sh"
AREA = ROOT / ".work/v1.2.1"
REAL_FIND = shutil.which("find")
REAL_DU = shutil.which("du")
REAL_PYTHON = shutil.which("python3")


def production_function(name: str) -> str:
    text = SOURCE.read_text(encoding="utf-8")
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

    def run_function(self, mode="validate", extra=None, unprivileged=False):
        definitions = "\n".join(production_function(name) for name in
                                ("snapshot_scan_sources", "snapshot_validate_tree", "snapshot_capacity_check", "copy_snapshot_tree", "snapshot_assert_provider_settled"))
        script = "set -euo pipefail\ndie(){ printf '%s\\n' \"$*\" >&2; exit 1; }\ninfo(){ :; }\n" + definitions
        script += '\nDEPLOY_DIR=$1\nSTAGING="$1/staging"\nVERSIONS_DIR="$1"\nQUIET=1\nSNAPSHOT_MIN_FREE_MB_VALUE=0\n'
        if mode == "capacity":
            script += 'SNAPSHOT_SOURCE_PATHS=("$1/data/runtime" "${1}/other")\nsnapshot_capacity_check\nprintf "%s\\n" "$SNAPSHOT_SOURCE_KIB"\n'
        elif mode == "copy":
            script += 'copy_snapshot_tree data/runtime\n'
        elif mode == "pending":
            script += 'snapshot_assert_provider_settled\n'
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


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SnapshotLiveTests))
    failures = len(result.failures) + len(result.errors)
    print(f"UNIT 快照实时预检：{result.testsRun - failures} 通过，{failures} 失败；不连接Docker或目标机。")
    sys.exit(0 if result.wasSuccessful() else 1)
