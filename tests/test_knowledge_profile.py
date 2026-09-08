#!/usr/bin/env python3
"""知识模型/缓存代次与恢复隔离回归；仅使用本地虚构目录和组件桩。"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/knowledge-profile.py"
COMPONENT = ROOT / "scripts/knowledge-component.js"
AREA = ROOT / ".work/v1.2.1"
AREA.mkdir(parents=True, exist_ok=True)
EVIDENCE = Path(tempfile.mkdtemp(prefix="knowledge-profile-unit-", dir=AREA))
SPEC = importlib.util.spec_from_file_location("knowledge_profile_tested", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
MINI = "Xenova/all-MiniLM-L6-v2"
MULTI = "MintplexLabs/multilingual-e5-small"
NOMIC = "Xenova/nomic-embed-text-v1"


def save(file: Path, value, mode=0o600):
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    file.chmod(mode)


def load(file: Path):
    return json.loads(file.read_text(encoding="utf-8"))


def tree(file: Path):
    """只读合成目录；链接仅记录目标，不跟随到其它位置。"""
    result = {}
    for candidate in [file, *sorted(file.rglob("*"))]:
        info = candidate.lstat()
        name = str(candidate.relative_to(file))
        metadata = (info.st_mode & 0o777, info.st_uid, info.st_gid)
        if candidate.is_symlink():
            result[name] = ("link", os.readlink(candidate), metadata)
        elif candidate.is_file():
            result[name] = ("file", candidate.read_bytes(), metadata)
        else:
            result[name] = ("directory", metadata)
    return result


class ProfileFixture(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=EVIDENCE))
        self.storage = self.root / "data/anythingllm"
        for relative in ("data/anythingllm/documents/custom-documents", "data/anythingllm/vector-cache",
                         "data/anythingllm/lancedb", "data/runtime", "knowledge", "config", "tmp"):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        (self.storage / "anythingllm.db").write_bytes(b"synthetic-component-database-before\0")
        (self.storage / ".env").write_text("SYNTHETIC_INTERNAL_KEY=fixture-only-not-real\n")
        (self.storage / ".env").chmod(0o600)
        (self.storage / "lancedb/fragment.bin").write_bytes(b"synthetic-lance-fragment")
        self.location = "custom-documents/kb_1111111111111111_doc_2222222222222222.md-fixture.json"
        self.projection = "kb_1111111111111111_doc_2222222222222222.md"
        save(self.storage / "documents" / self.location, {"pageContent": "虚构资料正文。"})
        self.old_profile = MODULE.profile(self.observed_value())
        self.old_key = MODULE.fingerprint(self.old_profile)
        self.manifest_path = self.root / "data/knowledge-manifest.json"
        self.profile_path = self.root / "data/runtime/knowledge-profile.json"
        self.manifest = {"version": 1, "files": {self.projection: {
            "sha256": "a" * 64, "locations": [self.location], "embedding_profile": self.old_key}},
            "pending_files": {}, "garbage_locations": [], "embedding_profile": self.old_key}
        save(self.manifest_path, self.manifest)
        save(self.root / "data/knowledge-projection.json", [self.projection])
        save(self.root / "data/runtime/knowledge-settings.json", {
            "schema_version": 1, "workspace_slug": "synthetic_workspace", "temperature": 0.7, "observed_at": 1000})
        save(self.root / "data/runtime/knowledge-lexical.json", {
            "schema_version": 1, "fixture": "synthetic-lexical-before", "documents": []})
        save(self.root / "data/runtime/knowledge-map.json", {"schema_version": 2, "documents": [{
            "library_id": "kb_1111111111111111", "document_id": "doc_2222222222222222",
            "projection": self.projection, "location": self.location}]})
        save(self.root / "knowledge/catalog.json", {"schema_version": 2, "libraries": []})
        save(self.root / "config/materials-applied.json", {"revision": 3, "state": "applied", "fixture": "before"})
        self.cache(self.location).write_bytes(b'{"fixture":"old-cache"}\n')
        self.observed_file = self.root / "tmp/observed.json"
        self.plan_file = self.root / "tmp/plan.json"
        self.backup = self.root / "backups/knowledge-profiles/generation.fixture"
        self.controls = ["data/runtime/session-" + "a" * 64 + ".json",
                         "data/runtime/owned-" + "a" * 64 + "-01.json",
                         "data/runtime/router/questions/" + "b" * 64 + ".json",
                         "config/runtime.yaml", "data/postgres/fixture.keep"]
        for name in self.controls:
            save(self.root / name, {"fixture": "before", "mode": "human", "jobs": ["old"], "generation": 2})

    def observed_value(self, model=MINI, size=1000, overlap=20, foreign=0):
        passage, query = MODULE.MODELS[model]
        return {"engine": "native", "model": model, "chunk_size": size,
                "chunk_overlap": overlap, "component_version": "1.16.1",
                "foreign_documents": foreign, "workspace_documents": 1, "workspace_exists": True,
                "passage_prefix": passage, "query_prefix": query}

    def cache(self, location):
        return self.storage / "vector-cache" / (str(uuid.uuid5(uuid.NAMESPACE_URL, location)) + ".json")

    def applied_profile(self):
        save(self.profile_path, {"schema_version": 1, "fingerprint": self.old_key,
             "profile": self.old_profile, "state": "applied", "applied_at": 1000}, 0o640)

    def invoke(self, action, *extra):
        return subprocess.run([sys.executable, str(SCRIPT), "--deploy-dir", str(self.root), action, *map(str, extra)],
                              capture_output=True, text=True, timeout=8, check=False)

    def succeeds(self, action, *extra):
        result = self.invoke(action, *extra)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("Traceback", result.stderr)
        return json.loads(result.stdout)

    def rejects(self, action, *extra):
        result = self.invoke(action, *extra)
        self.assertNotEqual(result.returncode, 0, "应拒绝但已接受：" + action)
        self.assertNotIn("Traceback", result.stderr)
        return result

    def make_plan(self, model=MULTI, size=768, observed=None):
        save(self.observed_file, observed or self.observed_value())
        value = self.succeeds("plan", "--observed", self.observed_file, "--model", model, "--chunk-size", size)
        save(self.plan_file, value)
        return value

    def preserve(self):
        self.plan = self.make_plan()
        self.succeeds("backup", "--plan", self.plan_file, "--backup", self.backup)

    def activate(self):
        self.preserve()
        self.succeeds("activate", "--backup", self.backup)

    def committable(self):
        self.activate()
        manifest = load(self.manifest_path)
        manifest["pending_files"] = {}
        manifest["garbage_locations"] = []
        for record in manifest["files"].values():
            record["embedding_profile"] = self.plan["fingerprint"]
            for location in record["locations"]:
                self.cache(location).write_bytes(b'{"fixture":"new-generation-cache"}\n')
        save(self.manifest_path, manifest)
        save(self.observed_file, self.observed_value(MULTI, 768))

    def test_profile_fingerprint_binds_model_splitter_and_prefixes(self):
        value = MODULE.profile(self.observed_value())
        self.assertEqual(MODULE.fingerprint(value), MODULE.fingerprint(dict(reversed(list(value.items())))))
        changed = [MODULE.profile(self.observed_value(MULTI)), MODULE.profile(self.observed_value(size=768)),
                   MODULE.profile(self.observed_value(overlap=19))]
        self.assertTrue(all(MODULE.fingerprint(item) != self.old_key for item in changed))
        multilingual = changed[0]
        self.assertEqual((multilingual["passage_prefix"], multilingual["query_prefix"]), ("passage: ", "query: "))

    def test_legal_small_chunks_are_not_rejected(self):
        for size in (1, 20, 99):
            with self.subTest(size=size):
                self.assertEqual(MODULE.profile(self.observed_value(size=size, overlap=0))["chunk_size"], size)

    def test_invalid_model_engine_version_and_boundaries_rejected(self):
        cases = [{"engine": "external"}, {"model": "unknown-fixture"}, {"component_version": "9.9.9"},
                 {"chunk_size": True}, {"chunk_size": 0}, {"chunk_size": 1001},
                 {"chunk_overlap": 1000}, {"chunk_overlap": -1}]
        for change in cases:
            with self.subTest(change=change), self.assertRaises(MODULE.KnowledgeError):
                MODULE.profile({**self.observed_value(), **change})

    def test_first_migration_requires_reindex_even_same_model(self):
        value = self.make_plan(MINI, 1000)
        self.assertTrue(value["requires_reindex"])
        self.assertFalse(self.profile_path.exists())

    def test_matching_applied_profile_is_idempotent(self):
        self.committable()
        self.succeeds("commit", "--backup", self.backup, "--observed", self.observed_file)
        value = self.make_plan(MULTI, 768, self.observed_value(MULTI, 768))
        self.assertFalse(value["requires_reindex"])

    def test_old_or_applying_profile_requires_reindex(self):
        for state in ("applied", "applying"):
            save(self.profile_path, {"fingerprint": self.old_key, "state": state, "profile": self.old_profile})
            self.assertTrue(self.make_plan()["requires_reindex"])

    def test_profile_match_does_not_hide_missing_cache(self):
        self.committable()
        self.succeeds("commit", "--backup", self.backup, "--observed", self.observed_file)
        self.cache(self.location).unlink()
        result = self.invoke("plan", "--observed", self.observed_file, "--model", MULTI, "--chunk-size", 768)
        self.assertTrue(result.returncode != 0 or json.loads(result.stdout)["requires_reindex"],
                        "同profile却丢缓存不得冒称无需重建")

    def test_profile_match_does_not_hide_changed_cache_bytes(self):
        self.committable()
        self.succeeds("commit", "--backup", self.backup, "--observed", self.observed_file)
        self.cache(self.location).write_bytes(b'{"fixture":"changed-after-commit"}\n')
        result = self.invoke("plan", "--observed", self.observed_file, "--model", MULTI, "--chunk-size", 768)
        self.assertTrue(result.returncode != 0 or json.loads(result.stdout)["requires_reindex"],
                        "已应用缓存字节变化必须重新对账")

    def test_profile_match_does_not_accept_hard_link_cache(self):
        self.committable()
        self.succeeds("commit", "--backup", self.backup, "--observed", self.observed_file)
        cache = self.cache(self.location)
        cache.unlink()
        target = self.root / "tmp/applied-cache-hardlink-target"
        target.write_bytes(b'{"fixture":"new-generation-cache"}\n')
        os.link(target, cache)
        result = self.invoke("plan", "--observed", self.observed_file, "--model", MULTI, "--chunk-size", 768)
        self.assertTrue(result.returncode != 0 or json.loads(result.stdout)["requires_reindex"],
                        "硬链接缓存不能被当前已应用代次接受")

    def test_profile_match_requires_all_cache_bindings(self):
        self.committable()
        self.succeeds("commit", "--backup", self.backup, "--observed", self.observed_file)
        manifest = load(self.manifest_path)
        manifest["files"][self.projection].pop("cache_bindings")
        save(self.manifest_path, manifest)
        result = self.invoke("plan", "--observed", self.observed_file, "--model", MULTI, "--chunk-size", 768)
        self.assertTrue(result.returncode != 0 or json.loads(result.stdout)["requires_reindex"],
                        "缺少缓存字节绑定不能只凭文件存在而跳过重建")

    def test_refresh_bindings_applied_is_atomic_and_idempotent(self):
        self.applied_profile()
        checked = self.succeeds("refresh-bindings", "--validate-only")
        self.assertEqual(checked["reason"], "validation_only")
        self.assertFalse(checked["changed"])
        self.assertEqual(checked["bindings"], 0)
        before = self.manifest_path.read_bytes()
        result = self.succeeds("refresh-bindings")
        self.assertTrue(result["changed"])
        self.assertFalse(result["skipped"])
        self.assertEqual(result["bindings"], 1)
        current = load(self.manifest_path)
        self.assertNotEqual(self.manifest_path.read_bytes(), before)
        self.assertEqual(current["files"][self.projection]["cache_bindings"], [{
            "location": self.location,
            "sha256": hashlib.sha256(self.cache(self.location).read_bytes()).hexdigest(),
        }])
        self.assertEqual(self.manifest_path.stat().st_mode & 0o777, 0o600)
        self.assertTrue(MODULE.current_profile_complete(self.root, load(self.profile_path), self.old_key))
        stable = self.manifest_path.read_bytes()
        second = self.succeeds("refresh-bindings")
        self.assertFalse(second["changed"])
        self.assertEqual(self.manifest_path.read_bytes(), stable)

    def test_refresh_bindings_never_replaces_an_existing_cache_digest(self):
        self.applied_profile()
        self.succeeds("refresh-bindings")
        original = self.manifest_path.read_bytes()
        self.cache(self.location).write_bytes(b'{"fixture":"tampered-cache"}\n')
        self.rejects("refresh-bindings", "--validate-only")
        self.rejects("refresh-bindings")
        self.assertEqual(self.manifest_path.read_bytes(), original)

    def test_refresh_bindings_manifest_limit_matches_runtime_limit(self):
        self.applied_profile()
        self.succeeds("refresh-bindings")
        compact = self.manifest_path.read_bytes()
        self.assertLess(len(compact), MODULE.MAX_MANIFEST_BYTES)
        self.manifest_path.write_bytes(compact.rstrip(b"\n") +
                                       b" " * (MODULE.MAX_MANIFEST_BYTES - len(compact.rstrip(b"\n"))))
        self.assertEqual(self.manifest_path.stat().st_size, MODULE.MAX_MANIFEST_BYTES)
        accepted = self.succeeds("refresh-bindings", "--validate-only")
        self.assertEqual(accepted["reason"], "validation_only")
        with self.manifest_path.open("ab") as stream:
            stream.write(b" ")
        self.assertEqual(self.manifest_path.stat().st_size, MODULE.MAX_MANIFEST_BYTES + 1)
        self.rejects("refresh-bindings", "--validate-only")
        self.rejects("refresh-bindings")

    def test_refresh_bindings_covers_new_updated_and_force_reindexed_records(self):
        self.applied_profile()
        self.succeeds("refresh-bindings")

        # 普通更新会替换缓存并由同步器重写记录；新动作须绑定新字节而非沿用旧摘要。
        self.cache(self.location).write_bytes(b'{"fixture":"ordinary-update-cache"}\n')
        manifest = load(self.manifest_path)
        manifest["files"][self.projection] = {"sha256": "b" * 64, "locations": [self.location],
                                                     "embedding_profile": self.old_key}
        save(self.manifest_path, manifest)
        self.succeeds("refresh-bindings")
        self.assertEqual(load(self.manifest_path)["files"][self.projection]["cache_bindings"][0]["sha256"],
                         hashlib.sha256(self.cache(self.location).read_bytes()).hexdigest())

        # 新增文档没有历史 binding，不能使整个 applied profile 永久变成不完整。
        extra_location = "custom-documents/kb_1111111111111111_doc_3333333333333333.md-fixture.json"
        save(self.storage / "documents" / extra_location, {"pageContent": "新增虚构资料。"})
        self.cache(extra_location).write_bytes(b'{"fixture":"new-document-cache"}\n')
        manifest = load(self.manifest_path)
        manifest["files"]["kb_1111111111111111_doc_3333333333333333.md"] = {
            "sha256": "c" * 64, "locations": [extra_location], "embedding_profile": self.old_key}
        save(self.manifest_path, manifest)
        added = self.succeeds("refresh-bindings")
        self.assertEqual(added["bindings"], 2)

        # 强制重索引会同时替换全部记录；所有条目都必须重新绑定，不能只补新增项。
        manifest = load(self.manifest_path)
        for index, record in enumerate(manifest["files"].values()):
            record.pop("cache_bindings", None)
            for location in record["locations"]:
                self.cache(location).write_bytes(("force-cache-%d\n" % index).encode())
        save(self.manifest_path, manifest)
        forced = self.succeeds("refresh-bindings")
        self.assertEqual(forced["bindings"], 2)
        for record in load(self.manifest_path)["files"].values():
            self.assertEqual(len(record["cache_bindings"]), len(record["locations"]))
            for binding in record["cache_bindings"]:
                self.assertEqual(binding["sha256"], hashlib.sha256(self.cache(binding["location"]).read_bytes()).hexdigest())

    def test_refresh_bindings_rejects_missing_empty_link_and_hard_link_cache(self):
        self.applied_profile()
        cache = self.cache(self.location)
        target = self.root / "tmp/cache-target"
        for kind in ("missing", "empty", "symlink", "hardlink"):
            with self.subTest(kind=kind):
                if cache.exists() or cache.is_symlink():
                    cache.unlink()
                if target.exists():
                    target.unlink()
                target.write_bytes(b'{"fixture":"link-target"}\n')
                if kind == "empty":
                    cache.write_bytes(b"")
                elif kind == "symlink":
                    cache.symlink_to(target)
                elif kind == "hardlink":
                    os.link(target, cache)
                before = self.manifest_path.read_bytes()
                self.rejects("refresh-bindings")
                self.assertEqual(self.manifest_path.read_bytes(), before)
        if cache.exists() or cache.is_symlink():
            cache.unlink()

    def test_refresh_bindings_blocks_unsettled_manifest_and_handles_migration_explicitly(self):
        self.applied_profile()
        original_manifest = load(self.manifest_path)
        for field, value in (("pending_files", {"pending.md": {"locations": [self.location]}}),
                             ("garbage_locations", [self.location])):
            with self.subTest(field=field):
                save(self.manifest_path, {**original_manifest, field: value})
                before = self.manifest_path.read_bytes()
                checked = self.succeeds("refresh-bindings", "--validate-only")
                self.assertEqual(checked["reason"], "validation_only")
                self.rejects("refresh-bindings")
                self.assertEqual(self.manifest_path.read_bytes(), before)
        save(self.manifest_path, original_manifest)
        migration = self.root / "data/runtime/knowledge-migration.json"
        self.backup.mkdir(parents=True)
        save(migration, {"schema_version": 1, "backup": str(self.backup)})
        self.rejects("refresh-bindings")
        migration.unlink()

        current = load(self.profile_path)
        current["state"] = "applying"
        save(self.profile_path, current, 0o640)
        self.rejects("refresh-bindings")
        save(migration, {"schema_version": 1, "backup": str(self.backup)})
        before = self.manifest_path.read_bytes()
        self.rejects("refresh-bindings")
        skipped = self.succeeds("refresh-bindings", "--allow-migration")
        self.assertTrue(skipped["skipped"])
        self.assertEqual(skipped["reason"], "migration_in_progress")
        self.assertFalse(skipped["changed"])
        self.assertEqual(self.manifest_path.read_bytes(), before)

        # commit 后 pointer 尚未清除的第二次 readback 只在绑定已经完整时允许跳过。
        current["state"] = "applied"
        save(self.profile_path, current, 0o640)
        incomplete = self.manifest_path.read_bytes()
        self.rejects("refresh-bindings", "--allow-migration")
        self.assertEqual(self.manifest_path.read_bytes(), incomplete)
        migration.unlink()
        self.succeeds("refresh-bindings")
        complete = self.manifest_path.read_bytes()
        save(migration, {"schema_version": 1, "backup": str(self.backup)})
        committed = self.succeeds("refresh-bindings", "--allow-migration")
        self.assertTrue(committed["skipped"])
        self.assertEqual(committed["reason"], "migration_committed")
        self.assertEqual(self.manifest_path.read_bytes(), complete)

        migration.unlink()
        invalid = self.root / "tmp/not-a-profile-backup"
        invalid.mkdir()
        save(migration, {"schema_version": 1, "backup": str(invalid)})
        self.rejects("refresh-bindings", "--allow-migration")

    def test_refresh_bindings_detects_concurrent_manifest_and_cache_changes(self):
        self.applied_profile()
        original_verify = MODULE.verify_identity
        original_manifest = load(self.manifest_path)

        changed = False
        def mutate_manifest(path, expected, empty=False):
            nonlocal changed
            if path == self.manifest_path and not changed:
                changed = True
                concurrent = load(self.manifest_path)
                concurrent["concurrent_fixture"] = True
                save(self.manifest_path, concurrent)
            return original_verify(path, expected, empty)

        with patch.object(MODULE, "verify_identity", side_effect=mutate_manifest), \
                self.assertRaises(MODULE.KnowledgeError):
            MODULE.refresh_bindings(self.root)
        self.assertTrue(load(self.manifest_path)["concurrent_fixture"])

        save(self.manifest_path, original_manifest)
        changed = False
        def mutate_cache(path, expected, empty=False):
            nonlocal changed
            if path == self.cache(self.location) and not changed:
                changed = True
                path.write_bytes(b'{"fixture":"concurrent-cache-change"}\n')
            return original_verify(path, expected, empty)

        before = self.manifest_path.read_bytes()
        with patch.object(MODULE, "verify_identity", side_effect=mutate_cache), \
                self.assertRaises(MODULE.KnowledgeError):
            MODULE.refresh_bindings(self.root)
        self.assertEqual(self.manifest_path.read_bytes(), before)

    def test_profile_payload_must_match_its_fingerprint(self):
        self.committable()
        self.succeeds("commit", "--backup", self.backup, "--observed", self.observed_file)
        current = load(self.profile_path)
        current["profile"]["chunk_size"] = 767
        save(self.profile_path, current)
        result = self.invoke("plan", "--observed", self.observed_file, "--model", MULTI, "--chunk-size", 768)
        self.assertTrue(result.returncode != 0 or json.loads(result.stdout)["requires_reindex"],
                        "profile正文损坏不能只信旧fingerprint字段")

    def test_foreign_workspace_prevents_global_model_or_chunk_change(self):
        save(self.observed_file, self.observed_value(foreign=2))
        for model, size in ((MULTI, 1000), (MINI, 768)):
            with self.subTest(model=model, size=size):
                self.rejects("plan", "--observed", self.observed_file, "--model", model, "--chunk-size", size)
        for count in (0, 2):
            with self.subTest(current_workspace_document_count=count):
                save(self.observed_file, {**self.observed_value(), "workspace_documents": count})
                self.rejects("plan", "--observed", self.observed_file, "--model", MULTI, "--chunk-size", 768)
        self.assertFalse(self.backup.exists())

    def test_uuidv5_cache_quarantine_is_exact_and_preserves_unrelated(self):
        pending = "custom-documents/pending-fixture.json"
        garbage = "custom-documents/garbage-fixture.json"
        unrelated = "custom-documents/another-workspace-fixture.json"
        for location in (pending, garbage, unrelated):
            self.cache(location).write_bytes(location.encode())
        self.manifest["pending_files"] = {"pending.md": {"locations": [pending]}}
        self.manifest["garbage_locations"] = [garbage]
        save(self.manifest_path, self.manifest)
        untouched = self.cache(unrelated).read_bytes()
        documents_before = tree(self.storage / "documents")
        self.activate()
        for location in (self.location, pending, garbage):
            self.assertFalse(self.cache(location).exists())
            self.assertTrue((self.backup / "quarantined-cache" / self.cache(location).name).is_file())
        self.assertEqual(self.cache(unrelated).read_bytes(), untouched)
        self.assertEqual(tree(self.storage / "documents"), documents_before)
        result = load(self.manifest_path)
        self.assertEqual(result["pending_files"], {})
        self.assertEqual(set(result["garbage_locations"]), {pending, garbage})

    def test_unsafe_document_locations_are_rejected(self):
        for location in ("../../escape.json", "custom-documents/../escape.json", "/absolute.json",
                         "custom-documents\\escape.json", "custom-documents/bad\n.json"):
            with self.subTest(location=location), self.assertRaises(MODULE.KnowledgeError):
                MODULE.cache_path(self.root, location)

    def test_commit_records_new_profile_and_cache_digest(self):
        self.committable()
        cache_bytes = self.cache(self.location).read_bytes()
        self.succeeds("commit", "--backup", self.backup, "--observed", self.observed_file)
        result = load(self.profile_path)
        self.assertEqual(result["state"], "applied")
        self.assertEqual(result["fingerprint"], self.plan["fingerprint"])
        self.assertEqual(self.profile_path.stat().st_mode & 0o777, 0o640)
        if os.geteuid() == 0:
            self.assertEqual((self.profile_path.stat().st_uid, self.profile_path.stat().st_gid), (0, 1000))
        binding = load(self.manifest_path)["files"][self.projection]["cache_bindings"]
        self.assertEqual(binding, [{"location": self.location, "sha256": hashlib.sha256(cache_bytes).hexdigest()}])

    def test_commit_rejects_old_record_profile(self):
        self.committable()
        manifest = load(self.manifest_path)
        manifest["files"][self.projection]["embedding_profile"] = self.old_key
        save(self.manifest_path, manifest)
        self.rejects("commit", "--backup", self.backup, "--observed", self.observed_file)
        self.assertEqual(load(self.profile_path)["state"], "applying")

    def test_commit_rejects_pending_or_garbage(self):
        self.committable()
        original = load(self.manifest_path)
        for name, value in (("pending_files", {"p": {"locations": [self.location]}}), ("garbage_locations", [self.location])):
            with self.subTest(name=name):
                save(self.manifest_path, {**original, name: value})
                self.rejects("commit", "--backup", self.backup, "--observed", self.observed_file)

    def test_commit_rejects_missing_cache(self):
        self.committable()
        self.cache(self.location).unlink()
        self.rejects("commit", "--backup", self.backup, "--observed", self.observed_file)

    def test_commit_rejects_hard_link_cache_without_publishing_applied(self):
        self.committable()
        cache = self.cache(self.location)
        cache.unlink()
        target = self.root / "tmp/cache-hardlink-target"
        target.write_bytes(b'{"fixture":"hardlink-cache"}\n')
        os.link(target, cache)
        before = self.manifest_path.read_bytes()
        self.rejects("commit", "--backup", self.backup, "--observed", self.observed_file)
        self.assertEqual(load(self.profile_path)["state"], "applying")
        self.assertEqual(self.manifest_path.read_bytes(), before)

    def test_commit_rejects_cache_inode_exchange_before_manifest_publish(self):
        self.committable()
        cache = self.cache(self.location)
        before = self.manifest_path.read_bytes()
        original_stable_digest = MODULE.stable_digest
        changed = False

        def exchange(path):
            nonlocal changed
            result = original_stable_digest(path)
            if path == cache and not changed:
                changed = True
                replacement = cache.with_suffix(".replacement")
                replacement.write_bytes(b'{"fixture":"exchanged-cache"}\n')
                os.replace(replacement, cache)
            return result

        arguments = [str(SCRIPT), "--deploy-dir", str(self.root), "commit", "--backup", str(self.backup),
                     "--observed", str(self.observed_file)]
        with patch.object(MODULE, "stable_digest", side_effect=exchange), \
                patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaises(MODULE.KnowledgeError):
            MODULE.main()
        self.assertEqual(load(self.profile_path)["state"], "applying")
        self.assertEqual(self.manifest_path.read_bytes(), before)

    def test_commit_rechecks_cache_after_manifest_publish_before_applied(self):
        self.committable()
        cache = self.cache(self.location)
        original_atomic = MODULE.atomic
        changed = False

        def change_after_manifest(path, value, mode=0o600):
            nonlocal changed
            original_atomic(path, value, mode)
            if path == self.manifest_path and not changed:
                changed = True
                replacement = cache.with_suffix(".replacement")
                replacement.write_bytes(b'{"fixture":"changed-after-manifest"}\n')
                os.replace(replacement, cache)

        arguments = [str(SCRIPT), "--deploy-dir", str(self.root), "commit", "--backup", str(self.backup),
                     "--observed", str(self.observed_file)]
        with patch.object(MODULE, "atomic", side_effect=change_after_manifest), \
                patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaises(MODULE.KnowledgeError):
            MODULE.main()
        self.assertEqual(load(self.profile_path)["state"], "applying")
        self.assertIn("cache_bindings", load(self.manifest_path)["files"][self.projection])

    def test_commit_rejects_manifest_change_after_stable_read(self):
        self.committable()
        original_decode = MODULE.decode_stable_json
        changed = False

        def change_manifest(path, maximum):
            nonlocal changed
            result = original_decode(path, maximum)
            if path == self.manifest_path and not changed:
                changed = True
                value = load(path)
                value["concurrent_fixture"] = True
                save(path, value)
            return result

        arguments = [str(SCRIPT), "--deploy-dir", str(self.root), "commit", "--backup", str(self.backup),
                     "--observed", str(self.observed_file)]
        with patch.object(MODULE, "decode_stable_json", side_effect=change_manifest), \
                patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaises(MODULE.KnowledgeError):
            MODULE.main()
        self.assertEqual(load(self.profile_path)["state"], "applying")
        self.assertNotIn("cache_bindings", load(self.manifest_path)["files"][self.projection])

    def test_commit_rejects_observed_change_after_stable_read(self):
        self.committable()
        original_decode = MODULE.decode_stable_json
        changed = False

        def change_observed(path, maximum):
            nonlocal changed
            result = original_decode(path, maximum)
            if path == self.observed_file and not changed:
                changed = True
                value = load(path)
                value["concurrent_fixture"] = True
                save(path, value)
            return result

        arguments = [str(SCRIPT), "--deploy-dir", str(self.root), "commit", "--backup", str(self.backup),
                     "--observed", str(self.observed_file)]
        with patch.object(MODULE, "decode_stable_json", side_effect=change_observed), \
                patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaises(MODULE.KnowledgeError):
            MODULE.main()
        self.assertEqual(load(self.profile_path)["state"], "applying")
        self.assertNotIn("cache_bindings", load(self.manifest_path)["files"][self.projection])
        self.assertEqual(load(self.profile_path)["state"], "applying")

    def test_commit_rejects_observed_model_or_chunks_mismatch(self):
        self.committable()
        for observed in (self.observed_value(), self.observed_value(MULTI, 767)):
            save(self.observed_file, observed)
            self.rejects("commit", "--backup", self.backup, "--observed", self.observed_file)

    def test_commit_requires_current_applying_plan(self):
        self.committable()
        save(self.profile_path, {"state": "applied", "fingerprint": self.old_key, "profile": self.old_profile})
        self.rejects("commit", "--backup", self.backup, "--observed", self.observed_file)

    def test_commit_requires_complete_backup(self):
        self.committable()
        (self.backup / "complete.json").unlink()
        self.rejects("commit", "--backup", self.backup, "--observed", self.observed_file)

    def test_backup_is_restricted_and_complete_for_anythingllm(self):
        before = tree(self.storage)
        self.preserve()
        self.assertEqual(tree(self.backup / "anythingllm"), before)
        self.assertEqual(self.backup.stat().st_mode & 0o777, 0o700)
        for name in ("plan.json", "complete.json"):
            self.assertEqual((self.backup / name).stat().st_mode & 0o777, 0o600)
        for name in self.controls:
            self.assertFalse((self.backup / "metadata" / name).exists())
        self.assertTrue((self.backup / "metadata/config/materials-applied.json").is_file())
        self.assertEqual(set(load(self.backup / "complete.json")["metadata"]), set(MODULE.METADATA) - {"data/runtime/knowledge-profile.json"})

    def test_restore_preserves_concurrent_human_jobs_owned_and_material_revision(self):
        original_storage = tree(self.storage)
        original_manifest = self.manifest_path.read_bytes()
        self.activate()
        (self.storage / "anythingllm.db").write_bytes(b"synthetic-new-component-database")
        (self.storage / "only-new-generation.bin").write_bytes(b"new")
        save(self.manifest_path, {"version": 1, "files": {}, "embedding_profile": "new"})
        for name in self.controls + ["config/materials-applied.json"]:
            save(self.root / name, {"fixture": "concurrent-after-backup", "mode": "human", "jobs": ["new", "old"], "generation": 7})
        protected = {name: (self.root / name).read_bytes() for name in self.controls + ["config/materials-applied.json"]}
        self.succeeds("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), original_storage)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)
        self.assertFalse(self.profile_path.exists(), "首次迁移回滚不能遗留新profile")
        for name, value in protected.items():
            self.assertEqual((self.root / name).read_bytes(), value, name)

    def test_backup_rejects_symlink_before_complete(self):
        self.make_plan()
        (self.storage / "unsafe-link").symlink_to(self.root / "config/runtime.yaml")
        self.rejects("backup", "--plan", self.plan_file, "--backup", self.backup)
        self.assertFalse((self.backup / "complete.json").exists())

    def test_backup_rejects_fifo_without_blocking(self):
        self.make_plan()
        os.mkfifo(self.storage / "unsafe-fifo")
        self.rejects("backup", "--plan", self.plan_file, "--backup", self.backup)
        self.assertFalse((self.backup / "complete.json").exists())

    def test_backup_rejects_hard_link_before_complete(self):
        self.make_plan()
        os.link(self.root / "config/runtime.yaml", self.storage / "unsafe-hard-link")
        self.rejects("backup", "--plan", self.plan_file, "--backup", self.backup)
        self.assertFalse((self.backup / "complete.json").exists())

    def test_backup_rejects_illegal_parent_and_symlink(self):
        self.make_plan()
        self.rejects("backup", "--plan", self.plan_file, "--backup", self.root / "tmp/generation.bad")
        parent = self.root / "backups/knowledge-profiles"
        parent.parent.mkdir(exist_ok=True)
        parent.symlink_to(self.root / "tmp", target_is_directory=True)
        self.rejects("backup", "--plan", self.plan_file, "--backup", self.backup)
        self.assertFalse((self.root / "tmp/generation.fixture").exists())

    def test_restore_missing_metadata_rejects_before_active_storage_swap(self):
        self.activate()
        (self.backup / "metadata/data/knowledge-manifest.json").unlink()
        (self.storage / "anythingllm.db").write_bytes(b"current-state-must-not-be-swapped")
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current, "损坏备份必须在替换当前组件目录之前拒绝")

    def test_restore_backup_child_symlink_rejects_before_swap(self):
        self.activate()
        saved = self.backup / "anythingllm"
        saved.rename(self.backup / "anythingllm-original")
        foreign = self.root / "tmp/unrelated-fixture"
        foreign.mkdir()
        (foreign / "must-not-be-imported").write_bytes(b"unrelated")
        saved.symlink_to(foreign, target_is_directory=True)
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    def test_restore_changed_backup_bytes_rejects_before_swap(self):
        self.activate()
        (self.backup / "anythingllm/anythingllm.db").write_bytes(b"corrupted-backup-fixture")
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    def test_restore_changed_backup_metadata_rejects_before_swap(self):
        self.activate()
        save(self.backup / "metadata/data/knowledge-manifest.json", {"files": {}, "fixture": "changed"})
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    def test_restore_changed_backup_mode_rejects_before_swap(self):
        self.activate()
        saved = self.backup / "anythingllm/anythingllm.db"
        saved.chmod((saved.stat().st_mode & 0o777) ^ 0o002)
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    def test_restore_changed_backup_root_mode_rejects_before_swap(self):
        self.activate()
        saved = self.backup / "anythingllm"
        saved.chmod((saved.stat().st_mode & 0o777) ^ 0o002)
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    def test_restore_metadata_root_symlink_rejects_before_swap(self):
        self.activate()
        saved = self.backup / "metadata"
        moved = self.backup / "metadata-original"
        saved.rename(moved)
        saved.symlink_to(moved, target_is_directory=True)
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    @unittest.skipUnless(os.geteuid() == 0, "非root只测模式权限，不伪造chown成功")
    def test_restore_changed_backup_owner_rejects_before_swap(self):
        self.activate()
        saved = self.backup / "anythingllm/anythingllm.db"
        original = saved.stat()
        os.chown(saved, original.st_uid, 1000 if original.st_gid != 1000 else 0)
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    def test_restore_rejects_non_whitelisted_complete_metadata(self):
        self.activate()
        complete = load(self.backup / "complete.json")
        complete["metadata"].append("data/runtime/session-" + "a" * 64 + ".json")
        save(self.backup / "complete.json", complete)
        current = tree(self.storage)
        protected = {name: (self.root / name).read_bytes() for name in self.controls}
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)
        for name, contents in protected.items():
            self.assertEqual((self.root / name).read_bytes(), contents)

    def test_restore_rejects_other_current_applying_plan(self):
        self.activate()
        save(self.profile_path, {"state": "applying", "fingerprint": "f" * 64, "profile": self.old_profile})
        current = tree(self.storage)
        self.rejects("restore", "--backup", self.backup)
        self.assertEqual(tree(self.storage), current)

    def test_activate_rejects_plan_not_bound_to_completed_backup(self):
        self.preserve()
        other = self.make_plan(NOMIC, 12000)
        self.assertNotEqual(other["fingerprint"], self.plan["fingerprint"])
        current = tree(self.storage)
        self.rejects("activate", "--backup", self.backup, "--plan", self.plan_file)
        self.assertEqual(tree(self.storage), current)

    def test_low_disk_space_refuses_backup_without_mutating_storage(self):
        self.make_plan()
        before = tree(self.storage)
        usage = shutil.disk_usage(self.root)
        argv = [str(SCRIPT), "--deploy-dir", str(self.root), "backup", "--plan", str(self.plan_file), "--backup", str(self.backup)]
        with patch.object(sys, "argv", argv), patch.object(MODULE.shutil, "disk_usage", return_value=usage._replace(free=0)), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(MODULE.KnowledgeError):
            MODULE.main()
        self.assertEqual(tree(self.storage), before)
        self.assertFalse((self.backup / "complete.json").exists())


NODE_HARNESS = r"""
const fs = require('node:fs'), vm = require('node:vm');
const input = JSON.parse(process.argv[1]);
let writes = [], embeddings = 0, output = '', errors = '', disconnected = false;
const info = {embeddingMaxChunkLength: input.maximum, chunkPrefix: '', queryPrefix: ''};
class NativeEmbedder {
  static supportedModels = {[input.model]: info};
  static _getEmbeddingModel() { return input.model; }
  async embedTextInput() { embeddings++; return [0.25, 0.5, 0.75]; }
}
const modules = {
  dotenv: {parse: () => ({}), config: () => ({})},
  './utils/EmbeddingEngines/native': {NativeEmbedder},
  './models/systemSettings': {SystemSettings: {
    updateSettings: async value => writes.push(value),
    getValueOrFallback: async ({label}, fallback) => label === 'text_splitter_chunk_size' ? (writes.at(-1)?.text_splitter_chunk_size ?? input.size) : (writes.at(-1)?.text_splitter_chunk_overlap ?? input.overlap ?? fallback)
  }},
  './utils/prisma': {workspaces: {findUnique: async () => ({id: 1})}, workspace_documents: {count: async ({where}) => typeof where.workspaceId === 'number' ? 1 : 0}, $disconnect: async () => {disconnected = true;}},
  './package.json': {version: '1.16.1'}
};
const fakeProcess = {argv: ['node', '-', input.action, 'synthetic_workspace', String(input.requestedSize), String(input.requestedOverlap)],
  env: {}, chdir: value => {if(value !== '/app/server') throw Error('unexpected path');},
  stdout: {write: value => {output += value;}}, stderr: {write: value => {errors += value;}}, exitCode: 0};
const context = {process: fakeProcess, console: {}, require: name => {
  if (name === 'fs') return {existsSync: () => false};
  if (name === 'module') return {createRequire: () => requested => {if(!Object.hasOwn(modules,requested)) throw Error('unexpected module'); return modules[requested];}};
  throw Error('unexpected module');
}};
(async () => {
  await vm.runInNewContext(fs.readFileSync(input.script,'utf8'), context, {timeout: 1000});
  process.stdout.write(JSON.stringify({exit: fakeProcess.exitCode, output: output ? JSON.parse(output) : null, errors, writes, embeddings, disconnected}));
})().catch(() => {process.stdout.write(JSON.stringify({harness_error:true}));process.exitCode=2;});
"""


class ComponentUnit(unittest.TestCase):
    def component(self, action, model=MINI, size=1000, maximum=1000, requested=768, overlap=20):
        result = subprocess.run(["node", "-e", NODE_HARNESS, json.dumps({"script": str(COMPONENT), "action": action,
            "model": model, "size": size, "maximum": maximum, "overlap": overlap,
            "requestedSize": requested, "requestedOverlap": overlap})], capture_output=True, text=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_observe_never_loads_or_embeds_model(self):
        result = self.component("observe")
        self.assertEqual(result["exit"], 0)
        self.assertEqual(result["embeddings"], 0)
        self.assertEqual(result["writes"], [])
        self.assertTrue(result["disconnected"])

    def test_explicit_probe_only_uses_synthetic_embedder(self):
        result = self.component("probe")
        self.assertEqual(result["exit"], 0)
        self.assertEqual(result["embeddings"], 1)
        self.assertEqual(result["writes"], [])

    def test_nomic_legal_larger_chunk_is_accepted(self):
        result = self.component("configure-chunks", model=NOMIC, size=16000, maximum=16000, requested=12000)
        self.assertEqual(result["exit"], 0, "组件不应把合法Nomic分块强制限制为1000")
        self.assertEqual(result["output"]["chunk_size"], 12000)

    def test_legal_small_chunk_is_accepted(self):
        result = self.component("configure-chunks", requested=20, overlap=0)
        self.assertEqual(result["exit"], 0, "合法正整数小分块不能被固定100下限拒绝")
        self.assertEqual(result["output"]["chunk_size"], 20)

    def test_out_of_range_chunk_does_not_write(self):
        result = self.component("configure-chunks", requested=1001)
        self.assertNotEqual(result["exit"], 0)
        self.assertEqual(result["writes"], [])
        self.assertEqual(result["embeddings"], 0)


if __name__ == "__main__":
    sources = [SCRIPT, COMPONENT, ROOT / "scripts/knowledge-profile.sh"]
    before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    transcript = io.StringIO()
    result = unittest.TextTestRunner(stream=transcript, verbosity=2).run(suite)
    after = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    failed_methods = {getattr(test, "test_case", test).id() for test, _ in result.failures + result.errors}
    summary = {"layer": "UNIT/COMPONENT-STUB", "tests_run": result.testsRun,
               "passed": result.testsRun - len(failed_methods) - len(result.skipped),
               "failed_methods": len(failed_methods), "skipped": len(result.skipped),
               "failure_count": len(result.failures), "error_count": len(result.errors),
               "failures": [{"test": test.id(), "kind": "assertion"} for test, _ in result.failures]
                    + [{"test": test.id(), "kind": "error"} for test, _ in result.errors],
               "target_connections": 0, "real_embedding_calls": 0, "real_model_calls": 0,
               "production_files_modified_by_test": False, "production_inputs_stable": before == after,
               "production_source_sha256": before}
    (EVIDENCE / "transcript.log").write_text(transcript.getvalue(), encoding="utf-8")
    (EVIDENCE / "transcript.log").chmod(0o600)
    print(transcript.getvalue(), end="")
    save(EVIDENCE / "result.json", summary)
    print(json.dumps(summary, ensure_ascii=False))
    print("合成证据目录：" + str(EVIDENCE.relative_to(ROOT)))
    sys.exit(0 if result.wasSuccessful() else 1)
